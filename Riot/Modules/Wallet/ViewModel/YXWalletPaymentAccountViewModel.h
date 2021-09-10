//
//  YXWalletPaymentAccountViewModel.h
//  lianliao
//
//  Created by liaoshen on 2021/6/24.
//  Copyright © 2021 https://www.vpubchain.info. All rights reserved.
//

#import "YXBaseViewModel.h"
#import "YXWalletPaymentAccountModel.h"
NS_ASSUME_NONNULL_BEGIN

@interface YXWalletPaymentAccountViewModel : YXBaseViewModel
@property (nonatomic , copy)dispatch_block_t reloadData;
@property (nonatomic , copy)void (^settingDefaultSuccessBlock)(YXWalletPaymentAccountRecordsItem *model);
@property (nonatomic , copy)void (^getDefaultAccountBlock)(YXWalletPaymentAccountRecordsItem *model);
@property (nonatomic , copy)void (^settingAccountNotiBlock)(void);
@property (nonatomic , copy)void (^touchSettingBlock)(YXWalletPaymentAccountRecordsItem *model);
@property (nonatomic , copy)void (^selectAccountBlock)(YXWalletPaymentAccountRecordsItem *model);//选中当前账户
@property (nonatomic , strong)YXWalletPaymentAccountModel *accountModel;
- (void)reloadNewData;
- (void)walletAccountSettingDefault:(YXWalletPaymentAccountRecordsItem *)model;
- (void)walletAccountCancleBangding:(YXWalletPaymentAccountRecordsItem *)model;
@end

NS_ASSUME_NONNULL_END
