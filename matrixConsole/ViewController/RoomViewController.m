/*
 Copyright 2014 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */
#import <MobileCoreServices/MobileCoreServices.h>

#import <MediaPlayer/MediaPlayer.h>

#import "RoomViewController.h"
#import "RoomMessage.h"
#import "RoomMessageTableCell.h"
#import "RoomMemberTableCell.h"
#import "RoomTitleView.h"

#import "MatrixHandler.h"
#import "AppDelegate.h"
#import "AppSettings.h"

#import "MediaManager.h"

#define ROOMVIEWCONTROLLER_UPLOAD_FILE_SIZE 5000000
#define ROOMVIEWCONTROLLER_BACK_PAGINATION_SIZE 20

#define ROOM_MESSAGE_CELL_DEFAULT_HEIGHT 50
#define ROOM_MESSAGE_CELL_DEFAULT_TEXTVIEW_TOP_CONST 10
#define ROOM_MESSAGE_CELL_DEFAULT_ATTACHMENTVIEW_TOP_CONST 18
#define ROOM_MESSAGE_CELL_HEIGHT_REDUCTION_WHEN_SENDER_INFO_IS_HIDDEN -10

#define ROOM_MESSAGE_CELL_TEXTVIEW_LEADING_AND_TRAILING_CONSTRAINT_TO_SUPERVIEW 120 // (51 + 69)

NSString *const kCmdChangeDisplayName = @"/nick";
NSString *const kCmdEmote = @"/me";
NSString *const kCmdJoinRoom = @"/join";
NSString *const kCmdKickUser = @"/kick";
NSString *const kCmdBanUser = @"/ban";
NSString *const kCmdUnbanUser = @"/unban";
NSString *const kCmdSetUserPowerLevel = @"/op";
NSString *const kCmdResetUserPowerLevel = @"/deop";


@interface RoomViewController () {
    BOOL forceScrollToBottomOnViewDidAppear;
    BOOL isJoinRequestInProgress;

    // Messages
    NSMutableArray *messages;
    id messagesListener;
    
    // Back pagination
    BOOL isBackPaginationInProgress;
    BOOL isFirstPagination;
    NSUInteger backPaginationAddedMsgNb;
    NSUInteger backPaginationHandledEventsNb;
    
    // Members list
    NSArray *members;
    id membersListener;
    
    // Attachment handling
    CustomImageView *highResImage;
    NSString *AVAudioSessionCategory;
    MPMoviePlayerController *videoPlayer;
    MPMoviePlayerController *tmpVideoPlayer;
    
    // used to trap the slide to close the keyboard
    UIView* inputAccessoryView;
    BOOL isKeyboardObserver;
    
    // Date formatter (nil if dateTime info is hidden)
    NSDateFormatter *dateFormatter;
    
    // Cache
    NSMutableArray *tmpCachedAttachments;
}

@property (weak, nonatomic) IBOutlet UINavigationItem *roomNavItem;
@property (weak, nonatomic) IBOutlet RoomTitleView *roomTitleView;
@property (weak, nonatomic) IBOutlet UITableView *messagesTableView;
@property (weak, nonatomic) IBOutlet UIView *controlView;
@property (weak, nonatomic) IBOutlet UIButton *optionBtn;
@property (weak, nonatomic) IBOutlet UITextField *messageTextField;
@property (weak, nonatomic) IBOutlet UIButton *sendBtn;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *controlViewBottomConstraint;
@property (weak, nonatomic) IBOutlet UIActivityIndicatorView *activityIndicator;
@property (weak, nonatomic) IBOutlet UIView *membersView;
@property (weak, nonatomic) IBOutlet UITableView *membersTableView;

@property (strong, nonatomic) MXRoom *mxRoom;
@property (strong, nonatomic) CustomAlert *actionMenu;
@end

@implementation RoomViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    forceScrollToBottomOnViewDidAppear = YES;
    // Hide messages table by default in order to hide initial scrolling to the bottom
    self.messagesTableView.hidden = YES;
    
    // Add tap detection on members view in order to hide members when the user taps outside members list
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideRoomMembers)];
    [tap setNumberOfTouchesRequired:1];
    [tap setNumberOfTapsRequired:1];
    [tap setDelegate:self];
    [self.membersView addGestureRecognizer:tap];
    
    isKeyboardObserver = NO;
    
    _sendBtn.enabled = NO;
    _sendBtn.alpha = 0.5;
    
    
    // add an input to check if the keyboard is hiding with sliding it
    inputAccessoryView = [[UIView alloc] initWithFrame:CGRectZero];
    self.messageTextField.inputAccessoryView = inputAccessoryView;
    
    // ensure that the titleView will be scaled when it will be required
    // during a screen rotation for example.
    self.roomTitleView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
}

- (void)dealloc {
    // Clear temporary cached attachments (used for local echo)
    NSUInteger index = tmpCachedAttachments.count;
    NSError *error = nil;
    while (index--) {
        if (![[NSFileManager defaultManager] removeItemAtPath:[tmpCachedAttachments objectAtIndex:index] error:&error]) {
            NSLog(@"Fail to delete cached media: %@", error);
        }
    }
    tmpCachedAttachments = nil;
    
    [self hideAttachmentView];
    
    messages = nil;
    if (messagesListener) {
        [self.mxRoom removeListener:messagesListener];
        messagesListener = nil;
        [[AppSettings sharedSettings] removeObserver:self forKeyPath:@"hideUnsupportedMessages"];
        [[AppSettings sharedSettings] removeObserver:self forKeyPath:@"displayAllEvents"];
        [[MatrixHandler sharedHandler] removeObserver:self forKeyPath:@"isResumeDone"];
    }
    self.mxRoom = nil;
    
    members = nil;
    if (membersListener) {
        membersListener = nil;
    }
    
    if (self.actionMenu) {
        [self.actionMenu dismiss:NO];
        self.actionMenu = nil;
    }
    
    if (dateFormatter) {
        dateFormatter = nil;
    }
    
    self.messageTextField.inputAccessoryView = inputAccessoryView = nil;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    if (isBackPaginationInProgress || isJoinRequestInProgress) {
        // Busy - be sure that activity indicator is running
        [self startActivityIndicator];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTextFieldChange:) name:UITextFieldTextDidChangeNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    // hide action
    if (self.actionMenu) {
        [self.actionMenu dismiss:NO];
        self.actionMenu = nil;
    }
    
    // Hide members by default
    [self hideRoomMembers];
    
    // slide to hide keyboard management
    if (isKeyboardObserver) {
        [inputAccessoryView.superview removeObserver:self forKeyPath:@"frame"];
        [inputAccessoryView.superview removeObserver:self forKeyPath:@"center"];
        isKeyboardObserver = NO;
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UITextFieldTextDidChangeNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // Set visible room id
    [AppDelegate theDelegate].masterTabBarController.visibleRoomId = self.roomId;
    
    if (forceScrollToBottomOnViewDidAppear) {
        dispatch_async(dispatch_get_main_queue(), ^{
           // Scroll to the bottom
            [self scrollToBottomAnimated:animated];
        });
        forceScrollToBottomOnViewDidAppear = NO;
        self.messagesTableView.hidden = NO;
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    // Reset visible room id
    [AppDelegate theDelegate].masterTabBarController.visibleRoomId = nil;
}

#pragma mark - room ID

- (void)setRoomId:(NSString *)roomId {
    if ([self.roomId isEqualToString:roomId] == NO) {
        _roomId = roomId;
        // Reload room data here
        [self configureView];
    }
}

#pragma mark - UIGestureRecognizer delegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.view == self.membersView) {
        // Compute actual frame of the displayed members list
        CGRect frame = self.membersTableView.frame;
        if (self.membersTableView.tableFooterView.frame.origin.y < frame.size.height) {
            frame.size.height = self.membersTableView.tableFooterView.frame.origin.y;
        }
        // gestureRecognizer should begin only if tap is outside members list
        return !CGRectContainsPoint(frame, [gestureRecognizer locationInView:self.membersView]);
    }
    return YES;
}

#pragma mark - Internal methods

- (void)configureView {
    // Check whether a request is in progress to join the room
    if (isJoinRequestInProgress) {
        // Busy - be sure that activity indicator is running
        [self startActivityIndicator];
        return;
    }
    
    // Remove potential listener
    if (messagesListener && self.mxRoom) {
        [self.mxRoom removeListener:messagesListener];
        messagesListener = nil;
        [[AppSettings sharedSettings] removeObserver:self forKeyPath:@"hideUnsupportedMessages"];
        [[AppSettings sharedSettings] removeObserver:self forKeyPath:@"displayAllEvents"];
        [[MatrixHandler sharedHandler] removeObserver:self forKeyPath:@"isResumeDone"];
    }
    // The whole room history is flushed here to rebuild it from the current instant (live)
    messages = nil;
    // Disable room title edition
    self.roomTitleView.editable = NO;
    
    // Update room data
    MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
    self.mxRoom = nil;
    if (self.roomId) {
        self.mxRoom = [mxHandler.mxSession roomWithRoomId:self.roomId];
    }
    if (self.mxRoom) {
        // Check first whether we have to join the room
        if (self.mxRoom.state.membership == MXMembershipInvite) {
            isJoinRequestInProgress = YES;
            [self startActivityIndicator];
            [self.mxRoom join:^{
                [self stopActivityIndicator];
                isJoinRequestInProgress = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self configureView];
                });
            } failure:^(NSError *error) {
                [self stopActivityIndicator];
                isJoinRequestInProgress = NO;
                NSLog(@"Failed to join room (%@): %@", self.mxRoom.state.displayname, error);
                //Alert user
                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
            return;
        }
        
        // Enable room title edition
        self.roomTitleView.editable = YES;
        
        messages = [NSMutableArray array];
        [[AppSettings sharedSettings] addObserver:self forKeyPath:@"hideUnsupportedMessages" options:0 context:nil];
        [[AppSettings sharedSettings] addObserver:self forKeyPath:@"displayAllEvents" options:0 context:nil];
        [[MatrixHandler sharedHandler] addObserver:self forKeyPath:@"isResumeDone" options:0 context:nil];
        // Register a listener to handle messages
        messagesListener = [self.mxRoom listenToEventsOfTypes:mxHandler.eventsFilterForMessages onEvent:^(MXEvent *event, MXEventDirection direction, MXRoomState *roomState) {
            // Handle first live events
            if (direction == MXEventDirectionForwards) {
                // Check user's membership in live room state (Indeed we have to go back on recents when user leaves, or is kicked/banned)
                if (self.mxRoom.state.membership == MXMembershipLeave || self.mxRoom.state.membership == MXMembershipBan) {
                    [[AppDelegate theDelegate].masterTabBarController popRoomViewControllerAnimated:NO];
                    return;
                }
                
                // Update Table
                BOOL isHandled = NO;
                BOOL shouldBeHidden = NO;
                // For outgoing message, remove the temporary event (local echo)
                if ([event.userId isEqualToString:[MatrixHandler sharedHandler].userId] && messages.count) {
                    // Consider first the last message
                    RoomMessage *message = [messages lastObject];
                    NSUInteger index = messages.count - 1;
                    if ([message containsEventId:event.eventId]) {
                        if (message.messageType == RoomMessageTypeText) {
                            // Removing temporary event (local echo)
                            [message removeEvent:event.eventId];
                            // Update message with the received event
                            isHandled = [message addEvent:event withRoomState:roomState];
                            if (!message.components.count) {
                                [self removeMessageAtIndex:index];
                            }
                        } else {
                            // Create a new message to handle attachment
                            message = [[RoomMessage alloc] initWithEvent:event andRoomState:roomState];
                            if (!message) {
                                // Ignore unsupported/unexpected events
                                [self removeMessageAtIndex:index];
                            } else {
                                [messages replaceObjectAtIndex:index withObject:message];
                            }
                            isHandled = YES;
                        }
                    } else {
                        // Look for the local echo among other messages, if it is not found (possible when our PUT is not returned yet), the added message will be hidden.
                        shouldBeHidden = YES;
                        while (index--) {
                            message = [messages objectAtIndex:index];
                            if ([message containsEventId:event.eventId]) {
                                if (message.messageType == RoomMessageTypeText) {
                                    // Removing temporary event (local echo)
                                    [message removeEvent:event.eventId];
                                    if (!message.components.count) {
                                        [self removeMessageAtIndex:index];
                                    }
                                } else {
                                    // Remove the local event (a new one will be added to messages)
                                    [self removeMessageAtIndex:index];
                                }
                                shouldBeHidden = NO;
                                break;
                            }
                        }
                    }
                }
                
                if (isHandled == NO) {
                    // Check whether the event may be grouped with last message
                    RoomMessage *lastMessage = [messages lastObject];
                    if (lastMessage && [lastMessage addEvent:event withRoomState:roomState]) {
                        isHandled = YES;
                    } else {
                        // Create a new item
                        lastMessage = [[RoomMessage alloc] initWithEvent:event andRoomState:roomState];
                        if (lastMessage) {
                            [messages addObject:lastMessage];
                            isHandled = YES;
                        } // else ignore unsupported/unexpected events
                    }
                    
                    if (isHandled && shouldBeHidden) {
                        [lastMessage hideComponent:YES withEventId:event.eventId];
                    }
                }
                
                // Refresh table display except if a back pagination is in progress
                if (!isBackPaginationInProgress) {
                    // We will scroll to bottom after updating tableView only if the most recent message is entirely visible.
                    CGFloat maxPositionY = self.messagesTableView.contentOffset.y + (self.messagesTableView.frame.size.height - self.messagesTableView.contentInset.bottom);
                    // Be a bit less retrictive, scroll even if the most recent message is partially hidden
                    maxPositionY += 30;
                    BOOL shouldScrollToBottom = (maxPositionY >= self.messagesTableView.contentSize.height);
                    // Refresh tableView
                    [self.messagesTableView reloadData];
                    
                    if (shouldScrollToBottom) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self scrollToBottomAnimated:YES];
                        });
                    }
                    
                    if (isHandled) {
                        if ([[AppDelegate theDelegate].masterTabBarController.visibleRoomId isEqualToString:self.roomId] == NO) {
                            // Some new events are received for this room while it is not visible, scroll to bottom on viewDidAppear to focus on them
                            forceScrollToBottomOnViewDidAppear = YES;
                        }
                    }
                }
            } else if (isBackPaginationInProgress && direction == MXEventDirectionBackwards) {
                // Back pagination is in progress, we add an old event at the beginning of messages
                RoomMessage *firstMessage = [messages firstObject];
                if (!firstMessage || [firstMessage addEvent:event withRoomState:roomState] == NO) {
                    firstMessage = [[RoomMessage alloc] initWithEvent:event andRoomState:roomState];
                    if (firstMessage) {
                        [messages insertObject:firstMessage atIndex:0];
                        backPaginationAddedMsgNb ++;
                        backPaginationHandledEventsNb ++;
                    }
                    // Ignore unsupported/unexpected events
                } else {
                    backPaginationHandledEventsNb ++;
                }
                
                // Display is refreshed at the end of back pagination (see onComplete block)
            }
        }];
        
        // Trigger a back pagination by reseting first backState to get room history from live
        [self.mxRoom resetBackState];
        [self triggerBackPagination];
    }
    
    self.roomTitleView.mxRoom = self.mxRoom;
    
    [self.messagesTableView reloadData];
}

- (void)scrollToBottomAnimated:(BOOL)animated {
    // Scroll table view to the bottom
    NSInteger rowNb = messages.count;
    // Check whether there is some data and whether the table has already been loaded
    if (rowNb && self.messagesTableView.contentSize.height) {
        [self.messagesTableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(rowNb - 1) inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:animated];
    }
}

- (void)removeMessageAtIndex:(NSUInteger)index {
    [messages removeObjectAtIndex:index];
    // Check whether the removed message was neither the first nor the last one
    if (index && index < messages.count) {
        RoomMessage *previousMessage = [messages objectAtIndex:index - 1];
        RoomMessage *nextMessage = [messages objectAtIndex:index];
        // Check whether both messages can merge
        if ([previousMessage mergeWithRoomMessage:nextMessage]) {
            [self removeMessageAtIndex:index];
        }
    }
}

- (void)triggerBackPagination {
    // Check whether a back pagination is already in progress
    if (isBackPaginationInProgress) {
        return;
    }
    
    if (self.mxRoom.canPaginate) {
        NSUInteger requestedItemsNb = ROOMVIEWCONTROLLER_BACK_PAGINATION_SIZE;
        // In case of first pagination, we will request only messages from the store to speed up the room display
        if (!messages.count) {
            isFirstPagination = YES;
            requestedItemsNb = self.mxRoom.remainingMessagesForPaginationInStore;
            if (!requestedItemsNb || ROOMVIEWCONTROLLER_BACK_PAGINATION_SIZE < requestedItemsNb) {
                requestedItemsNb = ROOMVIEWCONTROLLER_BACK_PAGINATION_SIZE;
            }
        }
        
        [self startActivityIndicator];
        isBackPaginationInProgress = YES;
        backPaginationAddedMsgNb = 0;
        
        [self paginateBackMessages:requestedItemsNb];
    }
}

- (void)paginateBackMessages:(NSUInteger)requestedItemsNb {
    backPaginationHandledEventsNb = 0;
    [self.mxRoom paginateBackMessages:requestedItemsNb complete:^{
        // Sanity check: check whether the view controller has not been released while back pagination was running
        if (self.roomId == nil) {
            return;
        }
        
        // Check whether we received less items than expected, and check condition to be able to ask more
        BOOL shouldLoop = ((backPaginationHandledEventsNb < requestedItemsNb) && self.mxRoom.canPaginate);
        if (shouldLoop) {
            NSUInteger missingItemsNb = requestedItemsNb - backPaginationHandledEventsNb;
            // About first pagination, we will loop only if the store has more items (except if none item has been handled, in this case loop is required)
            if (isFirstPagination && backPaginationHandledEventsNb) {
                if (self.mxRoom.remainingMessagesForPaginationInStore < missingItemsNb) {
                    missingItemsNb = self.mxRoom.remainingMessagesForPaginationInStore;
                }
            }
            
            if (missingItemsNb) {
                // Ask more items
                [self paginateBackMessages:missingItemsNb];
                return;
            }
        }
        // Here we are done
        [self onBackPaginationComplete];
    } failure:^(NSError *error) {
        [self onBackPaginationComplete];
        NSLog(@"Failed to paginate back: %@", error);
        //Alert user
        [[AppDelegate theDelegate] showErrorAsAlert:error];
    }];
}

- (void)onBackPaginationComplete {
    if (backPaginationAddedMsgNb) {
        // We scroll to bottom when table is loaded for the first time
        BOOL shouldScrollToBottom = (self.messagesTableView.contentSize.height == 0);
        
        CGFloat verticalOffset = 0;
        if (shouldScrollToBottom == NO) {
            // In this case, we will adjust the vertical offset in order to make visible only a few part of added messages (at the top of the table)
            NSIndexPath *indexPath;
            // Compute the cumulative height of the added messages
            for (NSUInteger index = 0; index < backPaginationAddedMsgNb; index++) {
                indexPath = [NSIndexPath indexPathForRow:index inSection:0];
                verticalOffset += [self tableView:self.messagesTableView heightForRowAtIndexPath:indexPath];
            }
            // Deduce the vertical offset from this height
            verticalOffset -= 100;
        }
        // Reset count to enable tableView update
        backPaginationAddedMsgNb = 0;
        // Reload
        [self.messagesTableView reloadData];
        // Adjust vertical content offset
        if (shouldScrollToBottom) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self scrollToBottomAnimated:NO];
            });
        } else if (verticalOffset > 0) {
            // Adjust vertical offset in order to limit scrolling down
            CGPoint contentOffset = self.messagesTableView.contentOffset;
            contentOffset.y = verticalOffset - self.messagesTableView.contentInset.top;
            [self.messagesTableView setContentOffset:contentOffset animated:NO];
        }
    }
    isFirstPagination = NO;
    isBackPaginationInProgress = NO;
    [self stopActivityIndicator];
}

- (void)startActivityIndicator {
    [_activityIndicator startAnimating];
}

- (void)stopActivityIndicator {
    // Check whether all conditions are satisfied before stopping loading wheel
    if ([[MatrixHandler sharedHandler] isResumeDone] && !isBackPaginationInProgress && !isJoinRequestInProgress) {
        [_activityIndicator stopAnimating];
    }
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([@"displayAllEvents" isEqualToString:keyPath]) {
        // Back to recents (Room details are not available until the end of initial sync)
        [[AppDelegate theDelegate].masterTabBarController popRoomViewControllerAnimated:NO];
    } else if ([@"hideUnsupportedMessages" isEqualToString:keyPath]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self configureView];
        });
    } else if ([@"isResumeDone" isEqualToString:keyPath]) {
        if ([[MatrixHandler sharedHandler] isResumeDone]) {
            [self stopActivityIndicator];
        } else {
            [self startActivityIndicator];
        }
    } else if ((object == inputAccessoryView.superview) && ([@"frame" isEqualToString:keyPath] || [@"center" isEqualToString:keyPath])) {
        
        // if the keyboard is displayed, check if the keyboard is hiding with a slide animation
        if (inputAccessoryView && inputAccessoryView.superview) {
            UIEdgeInsets insets = self.messagesTableView.contentInset;
            
            CGFloat screenHeight = 0;
            CGSize screenSize = [[UIScreen mainScreen] bounds].size;

            UIViewController* rootViewController = self;
            
            // get the root view controller to extract the application size
            while (rootViewController.parentViewController && ![rootViewController isKindOfClass:[UISplitViewController class]]) {
                rootViewController = rootViewController.parentViewController;
            }
            
            // IOS 6 ?
            // IOS 7 always gives the screen size in portrait
            // IOS 8 takes care about the orientation
            if (rootViewController.view.frame.size.width > rootViewController.view.frame.size.height) {
                screenHeight = MIN(screenSize.width, screenSize.height);
            }
            else {
                screenHeight = MAX(screenSize.width, screenSize.height);
            }
            
            insets.bottom = screenHeight - inputAccessoryView.superview.frame.origin.y;
            
            // Move the control view
            // Don't forget the offset related to tabBar
            CGFloat newConstant = insets.bottom - [AppDelegate theDelegate].masterTabBarController.tabBar.frame.size.height;
            
            // draw over the bound
            if ((_controlViewBottomConstraint.constant < 0) || (insets.bottom < self.controlView.frame.size.height)) {
                
                newConstant = 0;
                insets.bottom = self.controlView.frame.size.height;
            }
            else {
                // IOS 8 / landscape issue
                // when the top of the keyboard reaches the top of the tabbar, it triggers UIKeyboardWillShowNotification events in loop
                [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
            }
            // update the table the tableview height
            self.messagesTableView.contentInset = insets;
            _controlViewBottomConstraint.constant = newConstant;
        }
    }
}

# pragma mark - Room members

- (void)updateRoomMembers {
    NSArray* membersList = [self.mxRoom.state members];
    
    if (![[AppSettings sharedSettings] displayLeftUsers]) {
        NSMutableArray* filteredMembers = [[NSMutableArray alloc] init];
        
        for (MXRoomMember* member in membersList) {
            if (member.membership != MXMembershipLeave) {
                [filteredMembers addObject:member];
            }
        }
        
        membersList = filteredMembers;
    }
    
     members = [membersList sortedArrayUsingComparator:^NSComparisonResult(MXRoomMember *member1, MXRoomMember *member2) {
         // Move banned and left members at the end of the list
         if (member1.membership == MXMembershipLeave || member1.membership == MXMembershipBan) {
             if (member2.membership != MXMembershipLeave && member2.membership != MXMembershipBan) {
                 return NSOrderedDescending;
             }
         } else if (member2.membership == MXMembershipLeave || member2.membership == MXMembershipBan) {
             return NSOrderedAscending;
         }
         
         // Move invited members just before left and banned members
         if (member1.membership == MXMembershipInvite) {
             if (member2.membership != MXMembershipInvite) {
                 return NSOrderedDescending;
             }
         } else if (member2.membership == MXMembershipInvite) {
             return NSOrderedAscending;
         }
             
         if ([[AppSettings sharedSettings] sortMembersUsingLastSeenTime]) {
             // Get the users that correspond to these members
             MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
             MXUser *user1 = [mxHandler.mxSession userWithUserId:member1.userId];
             MXUser *user2 = [mxHandler.mxSession userWithUserId:member2.userId];
             
             // Move users who are not online or unavailable at the end (before invited users)
             if ((user1.presence == MXPresenceOnline) || (user1.presence == MXPresenceUnavailable)) {
                 if ((user2.presence != MXPresenceOnline) && (user2.presence != MXPresenceUnavailable)) {
                     return NSOrderedAscending;
                 }
             } else if ((user2.presence == MXPresenceOnline) || (user2.presence == MXPresenceUnavailable)) {
                 return NSOrderedDescending;
             } else {
                 // Here both users are neither online nor unavailable (the lastActive ago is useless)
                 // We will sort them according to their display, by keeping in front the offline users
                 if (user1.presence == MXPresenceOffline) {
                     if (user2.presence != MXPresenceOffline) {
                         return NSOrderedAscending;
                     }
                 } else if (user2.presence == MXPresenceOffline) {
                     return NSOrderedDescending;
                 }
                 return [[self.mxRoom.state memberName:member1.userId] compare:[self.mxRoom.state memberName:member2.userId] options:NSCaseInsensitiveSearch];
             }
             
             // Consider user's lastActive ago value
             if (user1.lastActiveAgo < user2.lastActiveAgo) {
                 return NSOrderedAscending;
             } else if (user1.lastActiveAgo == user2.lastActiveAgo) {
                 return [[self.mxRoom.state memberName:member1.userId] compare:[self.mxRoom.state memberName:member2.userId] options:NSCaseInsensitiveSearch];
             }
             return NSOrderedDescending;
         } else {
             // Move user without display name at the end (before invited users)
             if (member1.displayname.length) {
                 if (!member2.displayname.length) {
                     return NSOrderedAscending;
                 }
             } else if (member2.displayname.length) {
                 return NSOrderedDescending;
             }
             
             return [[self.mxRoom.state memberName:member1.userId] compare:[self.mxRoom.state memberName:member2.userId] options:NSCaseInsensitiveSearch];
         }
     }];
}

- (void)showRoomMembers {
    // Dismiss keyboard
    [self dismissKeyboard];
    
    [self updateRoomMembers];
    // Register a listener for events that concern room members
    MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
    NSArray *mxMembersEvents = @[
                                 kMXEventTypeStringRoomMember,
                                 kMXEventTypeStringRoomPowerLevels,
                                 kMXEventTypeStringPresence
                                 ];
    membersListener = [mxHandler.mxSession listenToEventsOfTypes:mxMembersEvents onEvent:^(MXEvent *event, MXEventDirection direction, id customObject) {
        // consider only live event
        if (direction == MXEventDirectionForwards) {
            // Check the room Id (if any)
            if (event.roomId && [event.roomId isEqualToString:self.roomId] == NO) {
                // This event does not concern the current room members
                return;
            }
            
            // Hide potential action sheet
            if (self.actionMenu) {
                [self.actionMenu dismiss:NO];
                self.actionMenu = nil;
            }
            // Refresh members list
            [self updateRoomMembers];
            [self.membersTableView reloadData];
        }
    }];
    
    self.membersView.hidden = NO;
    [self.membersTableView reloadData];
}

- (void)hideRoomMembers {
    if (membersListener) {
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        [mxHandler.mxSession removeListener:membersListener];
        membersListener = nil;
    }
    self.membersView.hidden = YES;
    members = nil;
}

# pragma mark - Attachment handling

- (void)showAttachmentView:(UIGestureRecognizer *)gestureRecognizer {
    CustomImageView *attachment = (CustomImageView*)gestureRecognizer.view;
    [self dismissKeyboard];
    
    // Retrieve attachment information
    NSDictionary *content = attachment.mediaInfo;
    NSUInteger msgtype = ((NSNumber*)content[@"msgtype"]).unsignedIntValue;
    if (msgtype == RoomMessageTypeImage) {
        NSString *url = content[@"url"];
        if (url.length) {
            highResImage = [[CustomImageView alloc] initWithFrame:self.membersView.frame];
            highResImage.contentMode = UIViewContentModeScaleAspectFit;
            highResImage.backgroundColor = [UIColor blackColor];
            highResImage.imageURL = url;
            [self.view addSubview:highResImage];
            
            // Add tap recognizer to hide attachment
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideAttachmentView)];
            [tap setNumberOfTouchesRequired:1];
            [tap setNumberOfTapsRequired:1];
            [highResImage addGestureRecognizer:tap];
            highResImage.userInteractionEnabled = YES;
        }
    } else if (msgtype == RoomMessageTypeVideo) {
        NSString *url =content[@"url"];
        if (url.length) {
            NSString *mimetype = nil;
            if (content[@"info"]) {
                mimetype = content[@"info"][@"mimetype"];
            }
            AVAudioSessionCategory = [[AVAudioSession sharedInstance] category];
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
            videoPlayer = [[MPMoviePlayerController alloc] init];
            if (videoPlayer != nil) {
                videoPlayer.scalingMode = MPMovieScalingModeAspectFit;
                [self.view addSubview:videoPlayer.view];
                [videoPlayer setFullscreen:YES animated:NO];
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(moviePlayerPlaybackDidFinishNotification:)
                                                             name:MPMoviePlayerPlaybackDidFinishNotification
                                                           object:nil];
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(moviePlayerWillExitFullscreen:)
                                                             name:MPMoviePlayerWillExitFullscreenNotification
                                                           object:videoPlayer];
                [MediaManager prepareMedia:url mimeType:mimetype success:^(NSString *cacheFilePath) {
                    if (cacheFilePath) {
                        if (tmpCachedAttachments == nil) {
                            tmpCachedAttachments = [NSMutableArray array];
                        }
                        if ([tmpCachedAttachments indexOfObject:cacheFilePath]) {
                            [tmpCachedAttachments addObject:cacheFilePath];
                        }
                    }
                    videoPlayer.contentURL = [NSURL fileURLWithPath:cacheFilePath];
                    [videoPlayer play];
                } failure:^(NSError *error) {
                    [self hideAttachmentView];
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            }
        }
    } else if (msgtype == RoomMessageTypeAudio) {
    } else if (msgtype == RoomMessageTypeLocation) {
    }
}

- (void)hideAttachmentView {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MPMoviePlayerPlaybackDidFinishNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MPMoviePlayerWillExitFullscreenNotification object:nil];
    
    if (highResImage) {
        [highResImage removeFromSuperview];
        highResImage = nil;
    }
    // Restore audio category
    if (AVAudioSessionCategory) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategory error:nil];
    }
    if (videoPlayer) {
        [videoPlayer stop];
        [videoPlayer setFullscreen:NO];
        [videoPlayer.view removeFromSuperview];
        videoPlayer = nil;
    }
}

- (void)moviePlayerWillExitFullscreen:(NSNotification*)notification {
    if (notification.object == videoPlayer) {
        [self hideAttachmentView];
    }
}

- (void)moviePlayerPlaybackDidFinishNotification:(NSNotification *)notification {
    NSDictionary *notificationUserInfo = [notification userInfo];
    NSNumber *resultValue = [notificationUserInfo objectForKey:MPMoviePlayerPlaybackDidFinishReasonUserInfoKey];
    MPMovieFinishReason reason = [resultValue intValue];
    
    // error cases
    if (reason == MPMovieFinishReasonPlaybackError) {
        NSError *mediaPlayerError = [notificationUserInfo objectForKey:@"error"];
        if (mediaPlayerError) {
            NSLog(@"Playback failed with error description: %@", [mediaPlayerError localizedDescription]);
            [self hideAttachmentView];
            //Alert user
            [[AppDelegate theDelegate] showErrorAsAlert:mediaPlayerError];
        }
    }
}

- (void)moviePlayerThumbnailImageRequestDidFinishNotification:(NSNotification *)notification {
    // Finalize video attachment
    UIImage* videoThumbnail = [[notification userInfo] objectForKey:MPMoviePlayerThumbnailImageKey];
    NSURL* selectedVideo = [tmpVideoPlayer contentURL];
    [tmpVideoPlayer stop];
    tmpVideoPlayer = nil;
    
    if (videoThumbnail && selectedVideo) {
        // Prepare video thumbnail description
        NSUInteger thumbnailSize = ROOM_MESSAGE_MAX_ATTACHMENTVIEW_WIDTH;
        UIImage *thumbnail = [MediaManager resize:videoThumbnail toFitInSize:CGSizeMake(thumbnailSize, thumbnailSize)];
        NSMutableDictionary *thumbnailInfo = [[NSMutableDictionary alloc] init];
        [thumbnailInfo setValue:@"image/jpeg" forKey:@"mimetype"];
        [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)thumbnail.size.width] forKey:@"w"];
        [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)thumbnail.size.height] forKey:@"h"];
        NSData *thumbnailData = UIImageJPEGRepresentation(thumbnail, 0.9);
        [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:thumbnailData.length] forKey:@"size"];
        
        // Create the local event displayed during uploading
        MXEvent *localEvent = [self addLocalEventForAttachedImage:thumbnail];
        
        // Upload thumbnail
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        [mxHandler.mxRestClient uploadContent:thumbnailData mimeType:@"image/jpeg" timeout:30 success:^(NSString *url) {
            // Prepare content of attached video
            NSMutableDictionary *videoContent = [[NSMutableDictionary alloc] init];
            NSMutableDictionary *videoInfo = [[NSMutableDictionary alloc] init];
            [videoContent setValue:@"m.video" forKey:@"msgtype"];
            [videoInfo setValue:url forKey:@"thumbnail_url"];
            [videoInfo setValue:thumbnailInfo forKey:@"thumbnail_info"];
            
            // Convert video container to mp4
            AVURLAsset* videoAsset = [AVURLAsset URLAssetWithURL:selectedVideo options:nil];
            AVAssetExportSession *exportSession = [AVAssetExportSession exportSessionWithAsset:videoAsset presetName:AVAssetExportPresetMediumQuality];
            // Set output URL
            NSString * outputFileName = [NSString stringWithFormat:@"%.0f.mp4",[[NSDate date] timeIntervalSince1970]];
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
            NSString *cacheRoot = [paths objectAtIndex:0];
            NSURL *tmpVideoLocation = [NSURL fileURLWithPath:[cacheRoot stringByAppendingPathComponent:outputFileName]];
            exportSession.outputURL = tmpVideoLocation;
            // Check supported output file type
            NSArray *supportedFileTypes = exportSession.supportedFileTypes;
            if ([supportedFileTypes containsObject:AVFileTypeMPEG4]) {
                exportSession.outputFileType = AVFileTypeMPEG4;
                [videoInfo setValue:@"video/mp4" forKey:@"mimetype"];
            } else {
                NSLog(@"Unexpected case: MPEG-4 file format is not supported");
                // we send QuickTime movie file by default
                exportSession.outputFileType = AVFileTypeQuickTimeMovie;
                [videoInfo setValue:@"video/quicktime" forKey:@"mimetype"];
            }
            // Export video file and send it
            [exportSession exportAsynchronouslyWithCompletionHandler:^{
                // Check status
                if ([exportSession status] == AVAssetExportSessionStatusCompleted) {
                    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:tmpVideoLocation
                                                            options:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                     [NSNumber numberWithBool:YES],
                                                                     AVURLAssetPreferPreciseDurationAndTimingKey,
                                                                     nil]
                                         ];
                    
                    [videoInfo setValue:[NSNumber numberWithDouble:(1000 * CMTimeGetSeconds(asset.duration))] forKey:@"duration"];
                    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
                    if (videoTracks.count > 0) {
                        AVAssetTrack *videoTrack = [videoTracks objectAtIndex:0];
                        CGSize videoSize = videoTrack.naturalSize;
                        [videoInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)videoSize.width] forKey:@"w"];
                        [videoInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)videoSize.height] forKey:@"h"];
                    }
                    
                    // Upload the video
                    NSData *videoData = [NSData dataWithContentsOfURL:tmpVideoLocation];
                    [[NSFileManager defaultManager] removeItemAtPath:[tmpVideoLocation path] error:nil];
                    if (videoData) {
                        if (videoData.length < ROOMVIEWCONTROLLER_UPLOAD_FILE_SIZE) {
                            [videoInfo setValue:[NSNumber numberWithUnsignedInteger:videoData.length] forKey:@"size"];
                            [mxHandler.mxRestClient uploadContent:videoData mimeType:videoInfo[@"mimetype"] timeout:30 success:^(NSString *url) {
                                [videoContent setValue:url forKey:@"url"];
                                [videoContent setValue:videoInfo forKey:@"info"];
                                [videoContent setValue:@"Video" forKey:@"body"];
                                [self postMessage:videoContent withLocalEvent:localEvent];
                            } failure:^(NSError *error) {
                                [self handleError:error forLocalEvent:localEvent];
                            }];
                        } else {
                            NSLog(@"Video is too large");
                            [self handleError:nil forLocalEvent:localEvent];
                        }
                    } else {
                        NSLog(@"Attach video failed: no data");
                        [self handleError:nil forLocalEvent:localEvent];
                    }
                }
                else {
                    NSLog(@"Video export failed: %d", (int)[exportSession status]);
                    // remove tmp file (if any)
                    [[NSFileManager defaultManager] removeItemAtPath:[tmpVideoLocation path] error:nil];
                    [self handleError:nil forLocalEvent:localEvent];
                }
            }];
        } failure:^(NSError *error) {
            NSLog(@"Video thumbnail upload failed");
            [self handleError:error forLocalEvent:localEvent];
        }];
    }
    
    [self dismissMediaPicker];
}

#pragma mark - Keyboard handling

- (void)onKeyboardWillShow:(NSNotification *)notif {
    // get the keyboard size
    NSValue *rectVal = notif.userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect endRect = rectVal.CGRectValue;
    
    // IOS 8 triggers some unexpected keyboard events
    if ((endRect.size.height == 0) || (endRect.size.width == 0)) {
        return;
    }
    
    UIEdgeInsets insets = self.messagesTableView.contentInset;
    // Handle portrait/landscape mode
    insets.bottom = (endRect.origin.y == 0) ? endRect.size.width : endRect.size.height;

    // bottom view offset
    // Don't forget the offset related to tabBar
    CGFloat nextBottomViewContanst = insets.bottom - [AppDelegate theDelegate].masterTabBarController.tabBar.frame.size.height;
    
    // get the animation info
    NSNumber *curveValue = [[notif userInfo] objectForKey:UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationCurve animationCurve = curveValue.intValue;
    
    // the duration is ignored but it is better to define it
    double animationDuration = [[[notif userInfo] objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    [UIView animateWithDuration:animationDuration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | (animationCurve << 16) animations:^{
        
        // Move up control view
        // Don't forget the offset related to tabBar
        _controlViewBottomConstraint.constant = nextBottomViewContanst;
        
        // reduce the tableview height
        self.messagesTableView.contentInset = insets;
        
        // scroll the tableview content
        [self scrollToBottomAnimated:NO];
        
        // force to redraw the layout (else _controlViewBottomConstraint.constant will not be animated)
        [self.view layoutIfNeeded];
        
    } completion:^(BOOL finished) {
        // be warned when the keyboard frame is updated
        [inputAccessoryView.superview addObserver:self forKeyPath:@"frame" options:0 context:nil];
        [inputAccessoryView.superview addObserver:self forKeyPath:@"center" options:0 context:nil];
        
        isKeyboardObserver = YES;
    }];
}

- (void)onKeyboardWillHide:(NSNotification *)notif {
    
    // onKeyboardWillHide seems being called several times by IOS
    if (isKeyboardObserver) {
        
        // IOS 8 / landscape issue
        // when the keyboard reaches the tabbar, it triggers UIKeyboardWillShowNotification events in loop
        // ensure that there is only one evene registration
        [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
        
        [inputAccessoryView.superview removeObserver:self forKeyPath:@"frame"];
        [inputAccessoryView.superview removeObserver:self forKeyPath:@"center"];
        isKeyboardObserver = NO;
    }

    // get the keyboard size
    NSValue *rectVal = notif.userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect endRect = rectVal.CGRectValue;
    
    rectVal = notif.userInfo[UIKeyboardFrameBeginUserInfoKey];
    CGRect beginRect = rectVal.CGRectValue;
    
    // IOS 8 triggers some unexpected keyboard events
    // it makes no sense if there is no update to animate
    if (CGRectEqualToRect(endRect, beginRect)) {
        return;
    }

    // get the animation info
    NSNumber *curveValue = [[notif userInfo] objectForKey:UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationCurve animationCurve = curveValue.intValue;
    
    // the duration is ignored but it is better to define it
    double animationDuration = [[[notif userInfo] objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    UIEdgeInsets insets = self.messagesTableView.contentInset;
    insets.bottom = self.controlView.frame.size.height;
    
    // animate the keyboard closing
    [UIView animateWithDuration:animationDuration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | (animationCurve << 16) animations:^{
        self.messagesTableView.contentInset = insets;
    
        _controlViewBottomConstraint.constant = 0;
        [self.view layoutIfNeeded];
        
    } completion:^(BOOL finished) {
    }];
}

- (void)dismissKeyboard {
    // Hide the keyboard
    [_messageTextField resignFirstResponder];
    [_roomTitleView dismissKeyboard];
}

#pragma mark - UITableView data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Check table view members vs messages
    if (tableView == self.membersTableView) {
        return members.count;
    }
    
    if (backPaginationAddedMsgNb) {
        // Here some old messages have been added to messages during back pagination.
        // Stop table refreshing, the table will be refreshed at the end of pagination
        return 0;
    }
    return messages.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Check table view members vs messages
    if (tableView == self.membersTableView) {
        // Use the same default height than message cell
        return ROOM_MESSAGE_CELL_DEFAULT_HEIGHT;
    }
    
    // Compute here height of message cell
    CGFloat rowHeight;
    RoomMessage* message = [messages objectAtIndex:indexPath.row];
    // Consider the specific case where the message is hidden (see outgoing messages temporarily hidden until our PUT is returned)
    if (message.messageType == RoomMessageTypeText && !message.attributedTextMessage.length) {
        return 0;
    }
    // Else compute height of message content (The maximum width available for the textview must be updated dynamically)
    message.maxTextViewWidth = self.messagesTableView.frame.size.width - ROOM_MESSAGE_CELL_TEXTVIEW_LEADING_AND_TRAILING_CONSTRAINT_TO_SUPERVIEW;
    rowHeight = message.contentSize.height;
    
    // Add top margin
    if (message.messageType == RoomMessageTypeText) {
        rowHeight += ROOM_MESSAGE_CELL_DEFAULT_TEXTVIEW_TOP_CONST;
    } else {
        rowHeight += ROOM_MESSAGE_CELL_DEFAULT_ATTACHMENTVIEW_TOP_CONST;
    }
    
    // Check whether the previous message has been sent by the same user.
    // The user's picture and name are displayed only for the first message.
    BOOL shouldHideSenderInfo = NO;
    if (indexPath.row) {
        RoomMessage *previousMessage = [messages objectAtIndex:indexPath.row - 1];
        shouldHideSenderInfo = [message hasSameSenderAsRoomMessage:previousMessage];
    }
    
    if (shouldHideSenderInfo) {
        // Reduce top margin -> row height reduction
        rowHeight += ROOM_MESSAGE_CELL_HEIGHT_REDUCTION_WHEN_SENDER_INFO_IS_HIDDEN;
    } else {
        // We consider a minimun cell height in order to display correctly user's picture
        if (rowHeight < ROOM_MESSAGE_CELL_DEFAULT_HEIGHT) {
            rowHeight = ROOM_MESSAGE_CELL_DEFAULT_HEIGHT;
        }
    }
    return rowHeight;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
    
    // Check table view members vs messages
    if (tableView == self.membersTableView) {
        RoomMemberTableCell *memberCell = [tableView dequeueReusableCellWithIdentifier:@"RoomMemberCell" forIndexPath:indexPath];
        if (indexPath.row < members.count) {
            [memberCell setRoomMember:[members objectAtIndex:indexPath.row] withRoom:self.mxRoom];
        }
        return memberCell;
    }
    
    // Handle here room message cells
    RoomMessage *message = [messages objectAtIndex:indexPath.row];
    // Consider the specific case where the message is hidden (see outgoing messages temporarily hidden until our PUT is returned)
    if (message.messageType == RoomMessageTypeText && !message.attributedTextMessage.length) {
        return [[UITableViewCell alloc] initWithFrame:CGRectZero];
    }
    // Else prepare the message cell
    RoomMessageTableCell *cell;
    BOOL isIncomingMsg = NO;
    
    if ([message.senderId isEqualToString:mxHandler.userId]) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"OutgoingMessageCell" forIndexPath:indexPath];
        OutgoingMessageTableCell* outgoingMsgCell = (OutgoingMessageTableCell*)cell;
        // Hide potential loading wheel
        [outgoingMsgCell.activityIndicator stopAnimating];
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:@"IncomingMessageCell" forIndexPath:indexPath];
        isIncomingMsg = YES;
    }
    
    // Restore initial settings
    cell.message = message;
    cell.attachmentView.imageURL = nil; // Cancel potential attachment loading
    cell.attachmentView.hidden = YES;
    cell.playIconView.hidden = YES;
    // Remove all gesture recognizer
    while (cell.attachmentView.gestureRecognizers.count) {
        [cell.attachmentView removeGestureRecognizer:cell.attachmentView.gestureRecognizers[0]];
    }
    // Remove potential dateTime (or unsent) label(s)
    if (cell.dateTimeLabelContainer.constraints.count) {
        if ([NSLayoutConstraint respondsToSelector:@selector(deactivateConstraints:)]) {
            [NSLayoutConstraint deactivateConstraints:cell.dateTimeLabelContainer.constraints];
        } else {
            [cell.dateTimeLabelContainer removeConstraints:cell.dateTimeLabelContainer.constraints];
        }
        for (UIView *view in cell.dateTimeLabelContainer.subviews) {
            [view removeFromSuperview];
        }
    }
    
    // Check whether the previous message has been sent by the same user.
    // The user's picture and name are displayed only for the first message.
    BOOL shouldHideSenderInfo = NO;
    if (indexPath.row) {
        RoomMessage *previousMessage = [messages objectAtIndex:indexPath.row - 1];
        shouldHideSenderInfo = [message hasSameSenderAsRoomMessage:previousMessage];
    }
    // Handle sender's picture and adjust view's constraints
    if (shouldHideSenderInfo) {
        cell.pictureView.hidden = YES;
        cell.msgTextViewTopConstraint.constant = ROOM_MESSAGE_CELL_DEFAULT_TEXTVIEW_TOP_CONST + ROOM_MESSAGE_CELL_HEIGHT_REDUCTION_WHEN_SENDER_INFO_IS_HIDDEN;
        cell.attachViewTopConstraint.constant = ROOM_MESSAGE_CELL_DEFAULT_ATTACHMENTVIEW_TOP_CONST + ROOM_MESSAGE_CELL_HEIGHT_REDUCTION_WHEN_SENDER_INFO_IS_HIDDEN;
        
    } else {
        cell.pictureView.hidden = NO;
        cell.msgTextViewTopConstraint.constant = ROOM_MESSAGE_CELL_DEFAULT_TEXTVIEW_TOP_CONST;
        cell.attachViewTopConstraint.constant = ROOM_MESSAGE_CELL_DEFAULT_ATTACHMENTVIEW_TOP_CONST;
        // Handle user's picture
        cell.pictureView.placeholder = @"default-profile";
        cell.pictureView.imageURL = message.senderAvatarUrl;
        [cell.pictureView.layer setCornerRadius:cell.pictureView.frame.size.width / 2];
        cell.pictureView.clipsToBounds = YES;
    }
    
    // Adjust top constraint constant for dateTime labels container, and hide it by default
    if (message.messageType == RoomMessageTypeText) {
        cell.dateTimeLabelContainerTopConstraint.constant = cell.msgTextViewTopConstraint.constant;
    } else {
        cell.dateTimeLabelContainerTopConstraint.constant = cell.attachViewTopConstraint.constant;
    }
    cell.dateTimeLabelContainer.hidden = YES;
    
    // Update incoming/outgoing message layout
    if (isIncomingMsg) {
        IncomingMessageTableCell* incomingMsgCell = (IncomingMessageTableCell*)cell;
        // Display user's display name except if the name appears in the displayed text (see emote and membership event)
        incomingMsgCell.userNameLabel.hidden = (shouldHideSenderInfo || message.startsWithSenderName);
        incomingMsgCell.userNameLabel.text = message.senderName;
    } else {
        // Add unsent label for failed components
        CGFloat yPosition = (message.messageType == RoomMessageTypeText) ? ROOM_MESSAGE_TEXTVIEW_MARGIN : -ROOM_MESSAGE_TEXTVIEW_MARGIN;
        for (RoomMessageComponent *component in message.components) {
            if (component.style == RoomMessageComponentStyleFailed) {
                UILabel *unsentLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, yPosition, 58 , 20)];
                unsentLabel.text = @"Unsent";
                unsentLabel.textAlignment = NSTextAlignmentCenter;
                unsentLabel.textColor = [UIColor redColor];
                unsentLabel.font = [UIFont systemFontOfSize:14];
                [cell.dateTimeLabelContainer addSubview:unsentLabel];
                cell.dateTimeLabelContainer.hidden = NO;
            }
            yPosition += component.height;
        }
    }
    
    // Set message content
    message.maxTextViewWidth = self.messagesTableView.frame.size.width - ROOM_MESSAGE_CELL_TEXTVIEW_LEADING_AND_TRAILING_CONSTRAINT_TO_SUPERVIEW;
    CGSize contentSize = message.contentSize;
    if (message.messageType != RoomMessageTypeText) {
        cell.messageTextView.hidden = YES;
        cell.attachmentView.hidden = NO;
        // Update image view frame in order to center loading wheel (if any)
        CGRect frame = cell.attachmentView.frame;
        frame.size.width = contentSize.width;
        frame.size.height = contentSize.height;
        cell.attachmentView.frame = frame;
        // Fade attachments during upload
        if (message.isUploadInProgress) {
            cell.attachmentView.alpha = 0.5;
            [((OutgoingMessageTableCell*)cell).activityIndicator startAnimating];
            cell.attachmentView.hideActivityIndicator = YES;
        } else {
            cell.attachmentView.alpha = 1;
            cell.attachmentView.hideActivityIndicator = NO;
        }
        NSString *url = message.thumbnailURL;
        if (!url && message.messageType == RoomMessageTypeImage) {
            url = message.attachmentURL;
        }
        if (message.messageType == RoomMessageTypeVideo) {
            cell.playIconView.hidden = NO;
        }
        
        cell.attachmentView.imageURL = url;
        if (url && message.attachmentURL && message.attachmentInfo) {
            // Add tap recognizer to open attachment
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showAttachmentView:)];
            [tap setNumberOfTouchesRequired:1];
            [tap setNumberOfTapsRequired:1];
            [tap setDelegate:self];
            [cell.attachmentView addGestureRecognizer:tap];
            // Store attachment content description used in showAttachmentView:
            cell.attachmentView.mediaInfo = @{@"msgtype" : [NSNumber numberWithUnsignedInt:message.messageType],
                                              @"url" : message.attachmentURL,
                                              @"info" : message.attachmentInfo};
        }
        
        // Adjust Attachment width constant
        cell.attachViewWidthConstraint.constant = contentSize.width;
    } else {
        cell.messageTextView.hidden = NO;
        if (!isIncomingMsg) {
            // Adjust horizontal position for outgoing messages (text is left aligned, but the textView should be right aligned)
            CGFloat leftInset = message.maxTextViewWidth - contentSize.width;
            cell.messageTextView.contentInset = UIEdgeInsetsMake(0, leftInset, 0, -leftInset);
        }
        cell.messageTextView.attributedText = message.attributedTextMessage;
    }
    
    // Handle timestamp display
    if (dateFormatter) {
        // Add datetime label for each component
        cell.dateTimeLabelContainer.hidden = NO;
        CGFloat yPosition = (message.messageType == RoomMessageTypeText) ? ROOM_MESSAGE_TEXTVIEW_MARGIN : -ROOM_MESSAGE_TEXTVIEW_MARGIN;
        for (RoomMessageComponent *component in message.components) {
            if (component.date && !component.isHidden) {
                UILabel *dateTimeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, yPosition, cell.dateTimeLabelContainer.frame.size.width , 20)];
                dateTimeLabel.text = [dateFormatter stringFromDate:component.date];
                if (isIncomingMsg) {
                    dateTimeLabel.textAlignment = NSTextAlignmentRight;
                } else {
                    dateTimeLabel.textAlignment = NSTextAlignmentLeft;
                }
                dateTimeLabel.textColor = [UIColor lightGrayColor];
                dateTimeLabel.font = [UIFont systemFontOfSize:12];
                dateTimeLabel.adjustsFontSizeToFitWidth = YES;
                dateTimeLabel.minimumScaleFactor = 0.6;
                [dateTimeLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
                [cell.dateTimeLabelContainer addSubview:dateTimeLabel];
                // Force dateTimeLabel in full width (to handle auto-layout in case of screen rotation)
                NSLayoutConstraint *leftConstraint = [NSLayoutConstraint constraintWithItem:dateTimeLabel
                                                                                  attribute:NSLayoutAttributeLeading
                                                                                  relatedBy:NSLayoutRelationEqual
                                                                                     toItem:cell.dateTimeLabelContainer
                                                                                  attribute:NSLayoutAttributeLeading
                                                                                 multiplier:1.0
                                                                                   constant:0];
                NSLayoutConstraint *rightConstraint = [NSLayoutConstraint constraintWithItem:dateTimeLabel
                                                                                   attribute:NSLayoutAttributeTrailing
                                                                                   relatedBy:NSLayoutRelationEqual
                                                                                      toItem:cell.dateTimeLabelContainer
                                                                                   attribute:NSLayoutAttributeTrailing
                                                                                  multiplier:1.0
                                                                                    constant:0];
                // Vertical constraints are required for iOS > 8
                NSLayoutConstraint *topConstraint = [NSLayoutConstraint constraintWithItem:dateTimeLabel
                                                                                 attribute:NSLayoutAttributeTop
                                                                                 relatedBy:NSLayoutRelationEqual
                                                                                    toItem:cell.dateTimeLabelContainer
                                                                                 attribute:NSLayoutAttributeTop
                                                                                multiplier:1.0
                                                                                  constant:yPosition];
                NSLayoutConstraint *heightConstraint = [NSLayoutConstraint constraintWithItem:dateTimeLabel
                                                                                    attribute:NSLayoutAttributeHeight
                                                                                    relatedBy:NSLayoutRelationEqual
                                                                                       toItem:nil
                                                                                    attribute:NSLayoutAttributeNotAnAttribute
                                                                                   multiplier:1.0
                                                                                     constant:20];
                if ([NSLayoutConstraint respondsToSelector:@selector(activateConstraints:)]) {
                    [NSLayoutConstraint activateConstraints:@[leftConstraint, rightConstraint, topConstraint, heightConstraint]];
                } else {
                    [cell.dateTimeLabelContainer addConstraint:leftConstraint];
                    [cell.dateTimeLabelContainer addConstraint:rightConstraint];
                    [cell.dateTimeLabelContainer addConstraint:topConstraint];
                    [dateTimeLabel addConstraint:heightConstraint];
                }
            }
            yPosition += component.height;
        }
    }
    return cell;
}

#pragma mark - UITableView delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // Check table view members vs messages
    if (tableView == self.membersTableView) {
        // List action(s) available on this member
        MXRoomMember *roomMember = [members objectAtIndex:indexPath.row];
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        __weak typeof(self) weakSelf = self;
        if (self.actionMenu) {
            [self.actionMenu dismiss:NO];
            self.actionMenu = nil;
        }
        
        // Consider the case of the user himself
        if ([roomMember.userId isEqualToString:mxHandler.userId]) {
            self.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an action:" message:nil style:CustomAlertStyleActionSheet];
            [self.actionMenu addActionWithTitle:@"Leave" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                if (weakSelf) {
                    weakSelf.actionMenu = nil;
                    MXRoom *currentRoom = [[MatrixHandler sharedHandler].mxSession roomWithRoomId:weakSelf.roomId];
                    [currentRoom leave:^{
                        // Back to recents
                        [[AppDelegate theDelegate].masterTabBarController popRoomViewControllerAnimated:YES];
                    } failure:^(NSError *error) {
                        NSLog(@"Leave room %@ failed: %@", weakSelf.roomId, error);
                        //Alert user
                        [[AppDelegate theDelegate] showErrorAsAlert:error];
                    }];
                }
            }];
        } else {
            // Check user's power level before allowing an action (kick, ban, ...)
            MXRoomPowerLevels *powerLevels = [self.mxRoom.state powerLevels];
            NSUInteger userPowerLevel = [powerLevels powerLevelOfUserWithUserID:mxHandler.userId];
            NSUInteger memberPowerLevel = [powerLevels powerLevelOfUserWithUserID:roomMember.userId];
            
            self.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an action:" message:nil style:CustomAlertStyleActionSheet];
            
            // Consider membership of the selected member
            switch (roomMember.membership) {
                case MXMembershipInvite:
                case MXMembershipJoin: {
                    // Check conditions to be able to kick someone
                    if (userPowerLevel >= [powerLevels kick] && userPowerLevel >= memberPowerLevel) {
                        [self.actionMenu addActionWithTitle:@"Kick" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                            if (weakSelf) {
                                weakSelf.actionMenu = nil;
                                [weakSelf.mxRoom kickUser:roomMember.userId
                                                   reason:nil
                                                  success:^{
                                                  }
                                                  failure:^(NSError *error) {
                                                      NSLog(@"Kick %@ failed: %@", roomMember.userId, error);
                                                      //Alert user
                                                      [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                  }];
                            }
                        }];
                    }
                    // Check conditions to be able to ban someone
                    if (userPowerLevel >= [powerLevels ban] && userPowerLevel >= memberPowerLevel) {
                        [self.actionMenu addActionWithTitle:@"Ban" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                            if (weakSelf) {
                                weakSelf.actionMenu = nil;
                                [weakSelf.mxRoom banUser:roomMember.userId
                                                  reason:nil
                                                 success:^{
                                                 }
                                                 failure:^(NSError *error) {
                                                     NSLog(@"Ban %@ failed: %@", roomMember.userId, error);
                                                     //Alert user
                                                     [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                 }];
                            }
                        }];
                    }
                    break;
                }
                case MXMembershipLeave: {
                    // Check conditions to be able to invite someone
                    if (userPowerLevel >= [powerLevels invite]) {
                        [self.actionMenu addActionWithTitle:@"Invite" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                            if (weakSelf) {
                                weakSelf.actionMenu = nil;
                                [weakSelf.mxRoom inviteUser:roomMember.userId
                                                    success:^{
                                                    }
                                                    failure:^(NSError *error) {
                                                        NSLog(@"Invite %@ failed: %@", roomMember.userId, error);
                                                        //Alert user
                                                        [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                    }];
                            }
                        }];
                    }
                    // Check conditions to be able to ban someone
                    if (userPowerLevel >= [powerLevels ban] && userPowerLevel >= memberPowerLevel) {
                        [self.actionMenu addActionWithTitle:@"Ban" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                            if (weakSelf) {
                                weakSelf.actionMenu = nil;
                                [weakSelf.mxRoom banUser:roomMember.userId
                                                  reason:nil
                                                 success:^{
                                                 }
                                                 failure:^(NSError *error) {
                                                     NSLog(@"Ban %@ failed: %@", roomMember.userId, error);
                                                     //Alert user
                                                     [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                 }];
                            }
                        }];
                    }
                    break;
                }
                case MXMembershipBan: {
                    // Check conditions to be able to unban someone
                    if (userPowerLevel >= [powerLevels ban] && userPowerLevel >= memberPowerLevel) {
                        [self.actionMenu addActionWithTitle:@"Unban" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                            if (weakSelf) {
                                weakSelf.actionMenu = nil;
                                [weakSelf.mxRoom unbanUser:roomMember.userId
                                                   success:^{
                                                   }
                                                   failure:^(NSError *error) {
                                                       NSLog(@"Unban %@ failed: %@", roomMember.userId, error);
                                                       //Alert user
                                                       [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                   }];
                            }
                        }];
                    }
                    break;
                }
                default: {
                    break;
                }
            }
            
            // the current web interface always creates a new room
            // uncoment this line opens any existing room with the same uers
            __block NSString* startedRoomID = nil; // [mxHandler getRoomStartedWithMember:roomMember];
            
            //, offer to chat with this user only
            if (startedRoomID) {
                [self.actionMenu addActionWithTitle:@"Open chat" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    // Open created room
                    [[AppDelegate theDelegate].masterTabBarController showRoom:startedRoomID];
                }];
            } else {
                [self.actionMenu addActionWithTitle:@"Start chat" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    // Create new room
                    [mxHandler.mxRestClient createRoom:(roomMember.displayname) ? roomMember.displayname : roomMember.userId
                                            visibility:kMXRoomVisibilityPrivate
                                             roomAlias:nil
                                                 topic:nil
                                               success:^(MXCreateRoomResponse *response) {
                                                   // add the user
                                                   [mxHandler.mxRestClient inviteUser:roomMember.userId toRoom:response.roomId success:^{
                                                       //NSLog(@"%@ has been invited (roomId: %@)", roomMember.userId, response.roomId);
                                                   } failure:^(NSError *error) {
                                                       NSLog(@"%@ invitation failed (roomId: %@): %@", roomMember.userId, response.roomId, error);
                                                       //Alert user
                                                       [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                   }];
                                                   
                                                   // Open created room
                                                   [[AppDelegate theDelegate].masterTabBarController showRoom:response.roomId];
                     
                                               } failure:^(NSError *error) {
                                                   NSLog(@"Create room failed: %@", error);
                                                   //Alert user
                                                   [[AppDelegate theDelegate] showErrorAsAlert:error];
                                               }];
                
                }];
            }
        }
        
        // Notify user when his power is too weak
        if (!self.actionMenu) {
            self.actionMenu = [[CustomAlert alloc] initWithTitle:nil message:@"You are not authorized to change the status of this member" style:CustomAlertStyleAlert];
        }
        
        // Display the action sheet (or the alert)
        if (self.actionMenu) {
            self.actionMenu.cancelButtonIndex = [self.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                weakSelf.actionMenu = nil;
            }];
            [self.actionMenu showInViewController:self];
        }
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else if (tableView == self.messagesTableView) {
        // Dismiss keyboard when user taps on messages table view content
        [self dismissKeyboard];
    }
}

// Detect vertical bounce at the top of the tableview to trigger pagination
- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (scrollView == self.messagesTableView) {
        // paginate ?
        if (scrollView.contentOffset.y < -64) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self triggerBackPagination];
            });
        }
    }
}

#pragma mark - UITextField delegate

- (void)onTextFieldChange:(NSNotification *)notification {
    if (notification.object == _messageTextField) {
        NSString *msg = _messageTextField.text;
        if (msg.length) {
            _sendBtn.enabled = YES;
            _sendBtn.alpha = 1;
            // Reset potential placeholder (used in case of wrong command usage)
            _messageTextField.placeholder = nil;
        } else {
            _sendBtn.enabled = NO;
            _sendBtn.alpha = 0.5;
        }
    }
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    NSString *alertMsg = nil;
    
    if (textField == _roomTitleView.displayNameTextField) {
        // Check whether the user has enough power to rename the room
        MXRoomPowerLevels *powerLevels = [self.mxRoom.state powerLevels];
        NSUInteger userPowerLevel = [powerLevels powerLevelOfUserWithUserID:[MatrixHandler sharedHandler].userId];
        if (userPowerLevel >= [powerLevels minimumPowerLevelForPostingEventAsStateEvent:kMXEventTypeStringRoomName]) {
            // Only the room name is edited here, update the text field with the room name
            textField.text = self.mxRoom.state.name;
            textField.backgroundColor = [UIColor whiteColor];
        } else {
            alertMsg = @"You are not authorized to edit this room name";
        }
        
        // Check whether the user is allowed to change room topic
        if (userPowerLevel >= [powerLevels minimumPowerLevelForPostingEventAsStateEvent:kMXEventTypeStringRoomTopic]) {
            // Show topic text field even if the current value is nil
            _roomTitleView.hiddenTopic = NO;
            if (alertMsg) {
                // Here the user can only update the room topic, switch on room topic field (without displaying alert)
                alertMsg = nil;
                [_roomTitleView.topicTextField becomeFirstResponder];
                return NO;
            }
        }
    } else if (textField == _roomTitleView.topicTextField) {
        // Check whether the user has enough power to edit room topic
        MXRoomPowerLevels *powerLevels = [self.mxRoom.state powerLevels];
        NSUInteger userPowerLevel = [powerLevels powerLevelOfUserWithUserID:[MatrixHandler sharedHandler].userId];
        if (userPowerLevel >= [powerLevels minimumPowerLevelForPostingEventAsStateEvent:kMXEventTypeStringRoomTopic]) {
            textField.backgroundColor = [UIColor whiteColor];
        } else {
            alertMsg = @"You are not authorized to edit this room topic";
        }
    }
    
    if (alertMsg) {
        // Alert user
        __weak typeof(self) weakSelf = self;
        if (self.actionMenu) {
            [self.actionMenu dismiss:NO];
        }
        self.actionMenu = [[CustomAlert alloc] initWithTitle:nil message:alertMsg style:CustomAlertStyleAlert];
        self.actionMenu.cancelButtonIndex = [self.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
            weakSelf.actionMenu = nil;
        }];
        [self.actionMenu showInViewController:self];
        return NO;
    }
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == _roomTitleView.displayNameTextField) {
        textField.backgroundColor = [UIColor clearColor];
        
        NSString *roomName = textField.text;
        if ((roomName.length || self.mxRoom.state.name.length) && [roomName isEqualToString:self.mxRoom.state.name] == NO) {
            [self startActivityIndicator];
            __weak typeof(self) weakSelf = self;
            [self.mxRoom setName:roomName success:^{
                [weakSelf stopActivityIndicator];
                // Refresh title display
                textField.text = weakSelf.mxRoom.state.displayname;
            } failure:^(NSError *error) {
                [weakSelf stopActivityIndicator];
                // Revert change
                textField.text = weakSelf.mxRoom.state.displayname;
                NSLog(@"Rename room failed: %@", error);
                //Alert user
                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
        } else {
            // No change on room name, restore title with room displayName
            textField.text = self.mxRoom.state.displayname;
        }
    } else if (textField == _roomTitleView.topicTextField) {
        textField.backgroundColor = [UIColor clearColor];
        
        NSString *topic = textField.text;
        if ((topic.length || self.mxRoom.state.topic.length) && [topic isEqualToString:self.mxRoom.state.topic] == NO) {
            [self startActivityIndicator];
            __weak typeof(self) weakSelf = self;
            [self.mxRoom setTopic:topic success:^{
                [weakSelf stopActivityIndicator];
                // Hide topic field if empty
                weakSelf.roomTitleView.hiddenTopic = !textField.text.length;
            } failure:^(NSError *error) {
                [weakSelf stopActivityIndicator];
                // Revert change
                textField.text = weakSelf.mxRoom.state.topic;
                // Hide topic field if empty
                weakSelf.roomTitleView.hiddenTopic = !textField.text.length;
                NSLog(@"Topic room change failed: %@", error);
                //Alert user
                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
        } else {
            // Hide topic field if empty
            _roomTitleView.hiddenTopic = !topic.length;
        }
    }
}

- (BOOL)textFieldShouldReturn:(UITextField*) textField {
    if (textField == _roomTitleView.displayNameTextField) {
        // "Next" key has been pressed
        [_roomTitleView.topicTextField becomeFirstResponder];
    } else {
        // "Done" key has been pressed
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - Actions

- (IBAction)onButtonPressed:(id)sender {
    if (sender == _sendBtn) {
        NSString *msgTxt = self.messageTextField.text;
        
        // Handle potential commands in room chat
        if ([self isIRCStyleCommand:msgTxt] == NO) {
            [self postTextMessage:msgTxt];
        }
        
        self.messageTextField.text = nil;
        // disable send button
        [self onTextFieldChange:nil];
    } else if (sender == _optionBtn) {
        [self dismissKeyboard];
        
        // Display action menu: Add attachments, Invite user...
        __weak typeof(self) weakSelf = self;
        self.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an action:" message:nil style:CustomAlertStyleActionSheet];
        // Attachments
        [self.actionMenu addActionWithTitle:@"Attach" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
            if (weakSelf) {
                // Ask for attachment type
                weakSelf.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an attachment type:" message:nil style:CustomAlertStyleActionSheet];
                [weakSelf.actionMenu addActionWithTitle:@"Media" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    if (weakSelf) {
                        weakSelf.actionMenu = nil;
                        // Open media gallery
                        UIImagePickerController *mediaPicker = [[UIImagePickerController alloc] init];
                        mediaPicker.delegate = weakSelf;
                        mediaPicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                        mediaPicker.allowsEditing = NO;
                        mediaPicker.mediaTypes = [NSArray arrayWithObjects:(NSString *)kUTTypeImage, (NSString *)kUTTypeMovie, nil];
                        [[AppDelegate theDelegate].masterTabBarController presentMediaPicker:mediaPicker];
                    }
                }];
                weakSelf.actionMenu.cancelButtonIndex = [weakSelf.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    weakSelf.actionMenu = nil;
                }];
                [weakSelf.actionMenu showInViewController:weakSelf];
            }
        }];
        // Invitation
        [self.actionMenu addActionWithTitle:@"Invite" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
            if (weakSelf) {
                // Ask for userId to invite
                weakSelf.actionMenu = [[CustomAlert alloc] initWithTitle:@"User ID:" message:nil style:CustomAlertStyleAlert];
                weakSelf.actionMenu.cancelButtonIndex = [weakSelf.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    weakSelf.actionMenu = nil;
                }];
                [weakSelf.actionMenu addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                    textField.secureTextEntry = NO;
                    textField.placeholder = @"ex: @bob:homeserver";
                }];
                [weakSelf.actionMenu addActionWithTitle:@"Invite" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    UITextField *textField = [alert textFieldAtIndex:0];
                    NSString *userId = textField.text;
                    weakSelf.actionMenu = nil;
                    if (userId.length) {
                        [weakSelf.mxRoom inviteUser:userId success:^{
                            
                        } failure:^(NSError *error) {
                            NSLog(@"Invite %@ failed: %@", userId, error);
                            //Alert user
                            [[AppDelegate theDelegate] showErrorAsAlert:error];
                        }];
                    }
                }];
                [weakSelf.actionMenu showInViewController:weakSelf];
            }
        }];
        self.actionMenu.cancelButtonIndex = [self.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
             weakSelf.actionMenu = nil;
        }];
        weakSelf.actionMenu.sourceView = weakSelf.optionBtn;
        [self.actionMenu showInViewController:self];
    }
}

- (IBAction)showHideDateTime:(id)sender {
    if (dateFormatter) {
        // dateTime will be hidden
        dateFormatter = nil;
    } else {
        // dateTime will be visible
        NSString *dateFormat = @"MMM dd HH:mm";
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:[[[NSBundle mainBundle] preferredLocalizations] objectAtIndex:0]]];
        [dateFormatter setFormatterBehavior:NSDateFormatterBehavior10_4];
        [dateFormatter setTimeStyle:NSDateFormatterNoStyle];
        [dateFormatter setDateFormat:dateFormat];
    }
    
    [self.messagesTableView reloadData];
}

- (IBAction)showHideRoomMembers:(id)sender {
    // Check whether the members list is displayed
    if (members) {
        [self hideRoomMembers];
    } else {
        [self hideAttachmentView];
        [self showRoomMembers];
    }
}

#pragma mark - Post messages

- (void)postMessage:(NSDictionary*)msgContent withLocalEvent:(MXEvent*)localEvent {
    MXMessageType msgType = msgContent[@"msgtype"];
    if (msgType) {
        // Check whether a temporary event has already been added for local echo (this happens on attachments)
        RoomMessage *message = nil;
        if (localEvent) {
            // Update the temporary event with the actual msg content
            NSUInteger index = messages.count;
            while (index--) {
                message = [messages objectAtIndex:index];
                if ([message containsEventId:localEvent.eventId]) {
                    localEvent.content = msgContent;
                    if (message.messageType == RoomMessageTypeText) {
                        [message removeEvent:localEvent.eventId];
                        [message addEvent:localEvent withRoomState:self.mxRoom.state];
                        if (!message.components.count) {
                            [self removeMessageAtIndex:index];
                        }
                    } else {
                        // Create a new message
                        message = [[RoomMessage alloc] initWithEvent:localEvent andRoomState:self.mxRoom.state];
                        if (message) {
                            // Refresh table display
                            [messages replaceObjectAtIndex:index withObject:message];
                        } else {
                            [self removeMessageAtIndex:index];
                        }
                    }
                    break;
                }
            }
            [self.messagesTableView reloadData];
        } else {
            // Create a temporary event to displayed outgoing message (local echo)
            NSString* localEventId = [NSString stringWithFormat:@"%@%@", kLocalEchoEventIdPrefix, [[NSProcessInfo processInfo] globallyUniqueString]];
            localEvent = [[MXEvent alloc] init];
            localEvent.roomId = self.roomId;
            localEvent.eventId = localEventId;
            localEvent.eventType = MXEventTypeRoomMessage;
            localEvent.type = kMXEventTypeStringRoomMessage;
            localEvent.content = msgContent;
            localEvent.userId = [MatrixHandler sharedHandler].userId;
            localEvent.originServerTs = kMXUndefinedTimestamp;
            // Check whether this new event may be grouped with last message
            RoomMessage *lastMessage = [messages lastObject];
            if (lastMessage == nil || [lastMessage addEvent:localEvent withRoomState:self.mxRoom.state] == NO) {
                // Create a new item
                lastMessage = [[RoomMessage alloc] initWithEvent:localEvent andRoomState:self.mxRoom.state];
                if (lastMessage) {
                    [messages addObject:lastMessage];
                } else {
                    NSLog(@"ERROR: Unable to add local event: %@", localEvent.description);
                }
            }
            [self.messagesTableView reloadData];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self scrollToBottomAnimated:NO];
            });
        }
        
        // Send message to the room
        [self.mxRoom postMessageOfType:msgType content:localEvent.content success:^(NSString *eventId) {
            // Check whether this event has already been received from events listener
            BOOL isEventAlreadyAddedToRoom = NO;
            NSUInteger index = messages.count;
            while (index--) {
                RoomMessage *message = [messages objectAtIndex:index];
                if ([message containsEventId:eventId]) {
                    isEventAlreadyAddedToRoom = YES;
                    // Remove hidden flag for this component into message
                    [message hideComponent:NO withEventId:eventId];
                    break;
                }
            }
            // Remove or update the temporary event
            index = messages.count;
            while (index--) {
                RoomMessage *message = [messages objectAtIndex:index];
                if ([message containsEventId:localEvent.eventId]) {
                    if (message.messageType == RoomMessageTypeText) {
                        [message removeEvent:localEvent.eventId];
                        if (isEventAlreadyAddedToRoom == NO) {
                            // Update the temporary event with the actual event id
                            localEvent.eventId = eventId;
                            [message addEvent:localEvent withRoomState:self.mxRoom.state];
                        }
                        if (!message.components.count) {
                            [self removeMessageAtIndex:index];
                        }
                    } else {
                        message = nil;
                        if (isEventAlreadyAddedToRoom == NO) {
                            // Create a new message
                            localEvent.eventId = eventId;
                            message = [[RoomMessage alloc] initWithEvent:localEvent andRoomState:self.mxRoom.state];
                        }
                        if (message) {
                            // Refresh table display
                            [messages replaceObjectAtIndex:index withObject:message];
                        } else {
                            [self removeMessageAtIndex:index];
                        }
                    }
                    break;
                }
            }
            
            // We will scroll to bottom after updating tableView only if the most recent message is entirely visible.
            CGFloat maxPositionY = self.messagesTableView.contentOffset.y + (self.messagesTableView.frame.size.height - self.messagesTableView.contentInset.bottom);
            // Be a bit less retrictive, scroll even if the most recent message is partially hidden
            maxPositionY += 30;
            BOOL shouldScrollToBottom = (maxPositionY >= self.messagesTableView.contentSize.height);
            
            // Refresh tableView
            [self.messagesTableView reloadData];
            
            if (shouldScrollToBottom) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self scrollToBottomAnimated:YES];
                });
            }
        } failure:^(NSError *error) {
            [self handleError:error forLocalEvent:localEvent];
        }];
    }
}

- (void)postTextMessage:(NSString*)msgTxt {
    MXMessageType msgType = kMXMessageTypeText;
    // Check whether the message is an emote
    if ([msgTxt hasPrefix:@"/me "]) {
        msgType = kMXMessageTypeEmote;
        // Remove "/me " string
        msgTxt = [msgTxt substringFromIndex:4];
    }
    
    [self postMessage:@{@"msgtype":msgType, @"body":msgTxt} withLocalEvent:nil];
}

- (MXEvent*)addLocalEventForAttachedImage:(UIImage*)image {
    // Create a temporary event to displayed outgoing message (local echo)
    NSString *localEventId = [NSString stringWithFormat:@"%@%@", kLocalEchoEventIdPrefix, [[NSProcessInfo processInfo] globallyUniqueString]];
    MXEvent *mxEvent = [[MXEvent alloc] init];
    mxEvent.roomId = self.roomId;
    mxEvent.eventId = localEventId;
    mxEvent.eventType = MXEventTypeRoomMessage;
    mxEvent.type = kMXEventTypeStringRoomMessage;
    mxEvent.originServerTs = kMXUndefinedTimestamp;
    // We store temporarily the image in cache, use the localId to build temporary url
    NSString *dummyURL = [NSString stringWithFormat:@"%@%@", kMediaManagerPrefixForDummyURL, localEventId];
    NSData *imageData = UIImageJPEGRepresentation(image, 0.5);
    NSString *cacheFilePath = [MediaManager cacheMediaData:imageData forURL:dummyURL mimeType:@"image/jpeg"];
    if (cacheFilePath) {
        if (tmpCachedAttachments == nil) {
            tmpCachedAttachments = [NSMutableArray array];
        }
        [tmpCachedAttachments addObject:cacheFilePath];
    }
    NSMutableDictionary *thumbnailInfo = [[NSMutableDictionary alloc] init];
    [thumbnailInfo setValue:@"image/jpeg" forKey:@"mimetype"];
    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)image.size.width] forKey:@"w"];
    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)image.size.height] forKey:@"h"];
    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:imageData.length] forKey:@"size"];
    mxEvent.content = @{@"msgtype":@"m.image", @"thumbnail_info":thumbnailInfo, @"thumbnail_url":dummyURL, @"url":dummyURL, @"info":thumbnailInfo};
    mxEvent.userId = [MatrixHandler sharedHandler].userId;
    
    // Update table sources
    RoomMessage *message = [[RoomMessage alloc] initWithEvent:mxEvent andRoomState:self.mxRoom.state];
    if (message) {
        [messages addObject:message];
    } else {
        NSLog(@"ERROR: Unable to add local event for attachment: %@", mxEvent.description);
    }
    [self.messagesTableView reloadData];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self scrollToBottomAnimated:NO];
    });
    
    return mxEvent;
}

- (void)handleError:(NSError *)error forLocalEvent:(MXEvent *)localEvent {
    NSLog(@"Post message failed: %@", error);
    if (error) {
        // Alert user
        [[AppDelegate theDelegate] showErrorAsAlert:error];
    }
    
    // Update the temporary event with this local event id
    NSUInteger index = messages.count;
    while (index--) {
        RoomMessage *message = [messages objectAtIndex:index];
        if ([message containsEventId:localEvent.eventId]) {
            NSLog(@"Posted event: %@", localEvent.description);
            if (message.messageType == RoomMessageTypeText) {
                [message removeEvent:localEvent.eventId];
                localEvent.eventId = kFailedEventId;
                [message addEvent:localEvent withRoomState:self.mxRoom.state];
                if (!message.components.count) {
                    [self removeMessageAtIndex:index];
                }
            } else {
                // Create a new message
                localEvent.eventId = kFailedEventId;
                message = [[RoomMessage alloc] initWithEvent:localEvent andRoomState:self.mxRoom.state];
                if (message) {
                    // Refresh table display
                    [messages replaceObjectAtIndex:index withObject:message];
                } else {
                    [self removeMessageAtIndex:index];
                }
            }
            break;
        }
    }
    [self.messagesTableView reloadData];
}

- (BOOL)isIRCStyleCommand:(NSString*)text{
    // Check whether the provided text may be an IRC-style command
    if ([text hasPrefix:@"/"] == NO || [text hasPrefix:@"//"] == YES) {
        return NO;
    }
    
    // Parse command line
    NSArray *components = [text componentsSeparatedByString:@" "];
    NSString *cmd = [components objectAtIndex:0];
    NSUInteger index = 1;
    
    if ([cmd isEqualToString:kCmdEmote]) {
        // post message as an emote
        [self postTextMessage:text];
    } else if ([text hasPrefix:kCmdChangeDisplayName]) {
        // Change display name
        NSString *displayName = [text substringFromIndex:kCmdChangeDisplayName.length + 1];
        // Remove white space from both ends
        displayName = [displayName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        if (displayName.length) {
            MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
            [mxHandler.mxRestClient setDisplayName:displayName success:^{
            } failure:^(NSError *error) {
                NSLog(@"Set displayName failed: %@", error);
                //Alert user
                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
        } else {
            // Display cmd usage in text input as placeholder
            self.messageTextField.placeholder = @"Usage: /nick <display_name>";
        }
    } else if ([text hasPrefix:kCmdJoinRoom]) {
        // Join a room
        NSString *roomAlias = [text substringFromIndex:kCmdJoinRoom.length + 1];
        // Remove white space from both ends
        roomAlias = [roomAlias stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        // Check
        if (roomAlias.length) {
            [[MatrixHandler sharedHandler].mxSession joinRoom:roomAlias success:^(MXRoom *room) {
                // Show the room
                [[AppDelegate theDelegate].masterTabBarController showRoom:room.state.roomId];
            } failure:^(NSError *error) {
                NSLog(@"Join roomAlias (%@) failed: %@", roomAlias, error);
                //Alert user
                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
        } else {
            // Display cmd usage in text input as placeholder
            self.messageTextField.placeholder = @"Usage: /join <room_alias>";
        }
    } else {
        // Retrieve userId
        NSString *userId = nil;
        while (index < components.count) {
            userId = [components objectAtIndex:index++];
            if (userId.length) {
                // done
                break;
            }
            // reset
            userId = nil;
        }
        
        if ([cmd isEqualToString:kCmdKickUser]) {
            if (userId) {
                // Retrieve potential reason
                NSString *reason = nil;
                while (index < components.count) {
                    if (reason) {
                        reason = [NSString stringWithFormat:@"%@ %@", reason, [components objectAtIndex:index++]];
                    } else {
                        reason = [components objectAtIndex:index++];
                    }
                }
                // Kick the user
                [self.mxRoom kickUser:userId reason:reason success:^{
                } failure:^(NSError *error) {
                    NSLog(@"Kick user (%@) failed: %@", userId, error);
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /kick <userId> [<reason>]";
            }
        } else if ([cmd isEqualToString:kCmdBanUser]) {
            if (userId) {
                // Retrieve potential reason
                NSString *reason = nil;
                while (index < components.count) {
                    if (reason) {
                        reason = [NSString stringWithFormat:@"%@ %@", reason, [components objectAtIndex:index++]];
                    } else {
                        reason = [components objectAtIndex:index++];
                    }
                }
                // Ban the user
                [self.mxRoom banUser:userId reason:reason success:^{
                } failure:^(NSError *error) {
                    NSLog(@"Ban user (%@) failed: %@", userId, error);
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /ban <userId> [<reason>]";
            }
        } else if ([cmd isEqualToString:kCmdUnbanUser]) {
            if (userId) {
                // Unban the user
                [self.mxRoom unbanUser:userId success:^{
                } failure:^(NSError *error) {
                    NSLog(@"Unban user (%@) failed: %@", userId, error);
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /unban <userId>";
            }
        } else if ([cmd isEqualToString:kCmdSetUserPowerLevel]) {
            // Retrieve power level
            NSString *powerLevel = nil;
            while (index < components.count) {
                powerLevel = [components objectAtIndex:index++];
                if (powerLevel.length) {
                    // done
                    break;
                }
                // reset
                powerLevel = nil;
            }
            // Set power level
            if (userId && powerLevel) {
                // Set user power level
                [self.mxRoom setPowerLevelOfUserWithUserID:userId powerLevel:[powerLevel integerValue] success:^{
                } failure:^(NSError *error) {
                    NSLog(@"Set user power (%@) failed: %@", userId, error);
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /op <userId> <power level>";
            }
        } else if ([cmd isEqualToString:kCmdResetUserPowerLevel]) {
            if (userId) {
                // Reset user power level
                [self.mxRoom setPowerLevelOfUserWithUserID:userId powerLevel:0 success:^{
                } failure:^(NSError *error) {
                    NSLog(@"Reset user power (%@) failed: %@", userId, error);
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /deop <userId>";
            }
        } else {
            NSLog(@"Unrecognised IRC-style command: %@", text);
            self.messageTextField.placeholder = [NSString stringWithFormat:@"Unrecognised IRC-style command: %@", cmd];
        }
    }
    return YES;
}

# pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSString *mediaType = [info objectForKey:UIImagePickerControllerMediaType];
    if ([mediaType isEqualToString:(NSString *)kUTTypeImage]) {
        UIImage *selectedImage = [info objectForKey:UIImagePickerControllerOriginalImage];
        if (selectedImage) {
            MXEvent *localEvent = [self addLocalEventForAttachedImage:selectedImage];
            // Upload image and its thumbnail
            MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
            NSUInteger thumbnailSize = ROOM_MESSAGE_MAX_ATTACHMENTVIEW_WIDTH;
            [mxHandler.mxRestClient uploadImage:selectedImage thumbnailSize:thumbnailSize timeout:30 success:^(NSDictionary *imageMessage) {
                // Send image
                [self postMessage:imageMessage withLocalEvent:localEvent];
            } failure:^(NSError *error) {
                [self handleError:error forLocalEvent:localEvent];
            }];
        }
    } else if ([mediaType isEqualToString:(NSString *)kUTTypeMovie]) {
        NSURL* selectedVideo = [info objectForKey:UIImagePickerControllerMediaURL];
        // Check the selected video, and ignore multiple calls (observed when user pressed several time Choose button)
        if (selectedVideo && !tmpVideoPlayer) {
            // Create video thumbnail
            tmpVideoPlayer = [[MPMoviePlayerController alloc] initWithContentURL:selectedVideo];
            if (tmpVideoPlayer) {
                [tmpVideoPlayer setShouldAutoplay:NO];
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(moviePlayerThumbnailImageRequestDidFinishNotification:)
                                                             name:MPMoviePlayerThumbnailImageRequestDidFinishNotification
                                                           object:nil];
                [tmpVideoPlayer requestThumbnailImagesAtTimes:@[@1.0f] timeOption:MPMovieTimeOptionNearestKeyFrame];
                // We will finalize video attachment when thumbnail will be available (see movie player callback)
                return;
            }
        }
    }

    [self dismissMediaPicker];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [self dismissMediaPicker];
}

- (void)dismissMediaPicker {
    [[AppDelegate theDelegate].masterTabBarController dismissMediaPicker];
}
@end
