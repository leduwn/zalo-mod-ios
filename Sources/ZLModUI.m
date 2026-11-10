// language: Objective-C, file: ZLModUI.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// ZLMod Customize dashboard and child management screens:
//   - ZLModConversationPoliciesViewController (per-conversation Seen/Typing/Unread)
//   - ZLModAntiRecallHistoryViewController (local Ghost Preview history & clear)
//   - ZLModQuickRepliesViewController (template CRUD, reorder, safe composer insert)
//   - ZLModPrivateNotesViewController (encrypted per-conversation notes)
//   - ZLModModuleStatusViewController (live HOOK_INSTALLED / NOT_INSTALLED status)
//   - ZLModLogViewerController (redacted bounded log viewer + clear)

#import "ZLMod.h"

extern NSString *ZLModGlassMaterialDescription(void);

#pragma mark - 1. Per-Conversation Policies Viewer

@interface ZLModConversationPoliciesViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *entries;
@end

@implementation ZLModConversationPoliciesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Per-Conversation Policies";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Xóa tất cả"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(clearAllTapped:)];
    [self reloadEntries];
}

- (void)reloadEntries {
    self.entries = [[ZLModConversationPolicyStore shared] summaryEntriesForCurrentAccount];
    self.navigationItem.rightBarButtonItem.enabled = (self.entries.count > 0);
    [self.tableView reloadData];
}

- (void)clearAllTapped:(__unused id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đặt lại chính sách hội thoại?"
                                                                   message:@"Xóa toàn bộ thiết lập Ẩn đã xem, Ẩn đang nhập và Chấm xanh chưa đọc của tài khoản hiện tại."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đặt lại"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModConversationPolicyStore shared] resetPoliciesForCurrentAccount];
        [self reloadEntries];
        ZLModShowToast(@"Đã đặt lại chính sách hội thoại");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)MAX(self.entries.count, (NSUInteger)1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"Mẹo: Nhấn giữ vào một cuộc trò chuyện bất kỳ ở danh sách tin nhắn Zalo để bật/tắt Ẩn đã xem, Ẩn đang nhập, Đánh dấu chưa đọc (Chấm xanh) hoặc Ghi chú riêng tư.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.entries.count == 0) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        empty.textLabel.text = @"Chưa có hội thoại nào được tùy chỉnh riêng";
        empty.textLabel.textColor = [UIColor secondaryLabelColor];
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    static NSString *cellId = @"ZLModPolicyCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *convType = [entry[@"convType"] isEqualToString:@"group"] ? @"Nhóm" : @"Cá nhân";
    cell.textLabel.text = [NSString stringWithFormat:@"%@ • %@", convType, entry[@"threadHash"] ?: @"id"];

    NSMutableArray<NSString *> *flags = [NSMutableArray array];
    if ([entry[@"hideSeen"] boolValue]) [flags addObject:@"Ẩn đã xem"];
    if ([entry[@"hideTyping"] boolValue]) [flags addObject:@"Ẩn đang nhập"];
    if ([entry[@"localUnread"] boolValue]) [flags addObject:@"Chấm xanh chưa đọc"];
    cell.detailTextLabel.text = [flags componentsJoinedByString:@" • "];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.entries.count == 0 || (NSUInteger)indexPath.row >= self.entries.count) return;

    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *compoundKey = entry[@"key"];
    if (![compoundKey isKindOfClass:[NSString class]]) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:entry[@"threadHash"] ?: @"Hội thoại"
                                                                   message:@"Đặt lại cuộc trò chuyện này về mặc định?"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Khôi phục mặc định"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModConversationPolicyStore shared] resetPolicyAtCompoundKey:compoundKey];
        [self reloadEntries];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = c ?: self.view;
        sheet.popoverPresentationController.sourceRect = c ? c.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - 2. Anti-Recall Local History Viewer

@interface ZLModAntiRecallHistoryViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *entries;
@end

@implementation ZLModAntiRecallHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Ghost Preview History";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Xóa lịch sử"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(clearTapped:)];
    [self reloadEntries];
}

- (void)reloadEntries {
    self.entries = [[ZLModAntiRecallStore shared] entriesForCurrentAccount];
    self.navigationItem.rightBarButtonItem.enabled = (self.entries.count > 0);
    [self.tableView reloadData];
}

- (void)clearTapped:(__unused id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xóa bản sao tin nhắn thu hồi?"
                                                                   message:@"Xóa toàn bộ lịch sử Ghost Preview đã mã hóa của tài khoản hiện tại."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xóa sạch"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModAntiRecallStore shared] clearCurrentAccountHistory];
        [self reloadEntries];
        ZLModShowToast(@"Đã xóa lịch sử Anti-Recall");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)MAX(self.entries.count, (NSUInteger)1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"Dữ liệu được mã hóa AES-256-CBC + HMAC-SHA256 bằng khóa trong iOS Keychain và tự động hết hạn sau 14 ngày. Chạm vào một dòng để giải mã và xem nội dung.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.entries.count == 0) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        empty.textLabel.text = @"Chưa có bản sao tin nhắn thu hồi nào";
        empty.textLabel.textColor = [UIColor secondaryLabelColor];
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    static NSString *cellId = @"ZLModRecallCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    NSDictionary *rec = self.entries[(NSUInteger)indexPath.row];
    NSDate *savedDate = [NSDate dateWithTimeIntervalSince1970:[rec[@"savedAt"] doubleValue]];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";

    cell.textLabel.text = [NSString stringWithFormat:@"Hội thoại %@ • Người gửi %@",
                           rec[@"threadHash"] ?: @"none",
                           rec[@"senderHash"] ?: @"none"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Lưu lúc %@ (Chạm để giải mã)", [fmt stringFromDate:savedDate]];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.entries.count == 0 || (NSUInteger)indexPath.row >= self.entries.count) return;

    NSDictionary *rec = self.entries[(NSUInteger)indexPath.row];
    NSString *key = rec[@"key"];
    NSString *revealed = [[ZLModAntiRecallStore shared] revealTextForEntryKey:key];
    if (!revealed) {
        revealed = @"Không thể giải mã bản ghi này (khóa hoặc ngữ cảnh không khớp).";
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Bản sao cục bộ"
                                                                   message:revealed
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Sao chép"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = revealed;
        ZLModShowToast(@"Đã sao chép vào bộ nhớ tạm");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - 3. Quick Replies View Controller

@interface ZLModQuickRepliesViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *templates;
@end

@implementation ZLModQuickRepliesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Quick Reply Templates";
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                            target:self
                                                                            action:@selector(addTapped:)];
    self.navigationItem.rightBarButtonItems = @[addBtn, self.editButtonItem];
    [self reloadTemplates];
}

- (void)reloadTemplates {
    self.templates = [[ZLModQuickReplyStore shared] quickReplies];
    [self.tableView reloadData];
}

- (void)addTapped:(__unused id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thêm mẫu trả lời nhanh"
                                                                   message:@"Nội dung chỉ được điền vào ô nhập tin nhắn, không bao giờ tự động gửi."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Nhập nội dung mẫu...";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Thêm"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        if ([[ZLModQuickReplyStore shared] addQuickReply:text]) {
            [self reloadTemplates];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)MAX(self.templates.count, (NSUInteger)1);
    return 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (section == 0) ? @"Mẫu câu (Chạm để chèn vào khung chat hoặc sửa)" : @"Tác vụ";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        UITableViewCell *resetCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        resetCell.textLabel.text = @"Khôi phục mẫu câu mặc định";
        resetCell.textLabel.textColor = [UIColor systemRedColor];
        return resetCell;
    }

    if (self.templates.count == 0) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        empty.textLabel.text = @"Chưa có mẫu câu nào (Nhấn + để thêm)";
        empty.textLabel.textColor = [UIColor secondaryLabelColor];
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    static NSString *cellId = @"ZLModQuickReplyCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.textLabel.numberOfLines = 2;
    }
    cell.textLabel.text = self.templates[(NSUInteger)indexPath.row];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (BOOL)tableView:(__unused UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return (indexPath.section == 0 && self.templates.count > 0);
}

- (BOOL)tableView:(__unused UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return (indexPath.section == 0 && self.templates.count > 1);
}

- (void)tableView:(__unused UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 0) {
        [[ZLModQuickReplyStore shared] removeQuickReplyAtIndex:(NSUInteger)indexPath.row];
        [self reloadTemplates];
    }
}

- (void)tableView:(__unused UITableView *)tableView
moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != 0 || destinationIndexPath.section != 0) {
        [self reloadTemplates];
        return;
    }
    [[ZLModQuickReplyStore shared] moveQuickReplyFromIndex:(NSUInteger)sourceIndexPath.row
                                                   toIndex:(NSUInteger)destinationIndexPath.row];
    [self reloadTemplates];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        [[ZLModQuickReplyStore shared] resetDefaults];
        [self reloadTemplates];
        ZLModShowToast(@"Đã khôi phục mẫu câu mặc định");
        return;
    }
    if (self.templates.count == 0 || (NSUInteger)indexPath.row >= self.templates.count) return;

    NSUInteger rowIdx = (NSUInteger)indexPath.row;
    NSString *templateText = self.templates[rowIdx];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Mẫu trả lời nhanh"
                                                                   message:templateText
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chèn vào khung chat đang mở"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        if ([[ZLModQuickReplyStore shared] insertTemplateIntoComposer:templateText]) {
            ZLModShowToast(@"Đã điền vào khung nhập tin nhắn");
        } else {
            [UIPasteboard generalPasteboard].string = templateText;
            ZLModShowToast(@"Không có khung chat đang mở — đã sao chép vào bộ nhớ tạm");
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chỉnh sửa mẫu câu..."
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIAlertController *edit = [UIAlertController alertControllerWithTitle:@"Chỉnh sửa mẫu câu"
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [edit addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = templateText;
        }];
        [edit addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [edit addAction:[UIAlertAction actionWithTitle:@"Lưu"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *a) {
            NSString *updated = edit.textFields.firstObject.text ?: @"";
            if ([[ZLModQuickReplyStore shared] updateQuickReplyAtIndex:rowIdx withText:updated]) {
                [self reloadTemplates];
            }
        }]];
        [self presentViewController:edit animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Xóa mẫu này"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModQuickReplyStore shared] removeQuickReplyAtIndex:rowIdx];
        [self reloadTemplates];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = c ?: self.view;
        sheet.popoverPresentationController.sourceRect = c ? c.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - 4. Encrypted Private Notes Viewer

@interface ZLModPrivateNotesViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, NSString *> *> *entries;
@end

@implementation ZLModPrivateNotesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Encrypted Private Notes";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Xóa tất cả"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(clearAllTapped:)];
    [self reloadNotes];
}

- (void)reloadNotes {
    self.entries = [[ZLModPrivateNotesStore shared] allEntriesForCurrentAccount];
    self.navigationItem.rightBarButtonItem.enabled = (self.entries.count > 0);
    [self.tableView reloadData];
}

- (void)clearAllTapped:(__unused id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xóa toàn bộ ghi chú?"
                                                                   message:@"Xóa toàn bộ ghi chú riêng tư đã mã hóa của tài khoản hiện tại."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xóa"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModPrivateNotesStore shared] clearCurrentAccountNotes];
        [self reloadNotes];
        ZLModShowToast(@"Đã xóa tất cả ghi chú riêng tư");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)MAX(self.entries.count, (NSUInteger)1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"Mẹo: Nhấn giữ vào một cuộc trò chuyện ở danh sách tin nhắn Zalo rồi chọn \"Ghi chú riêng tư\" để thêm hoặc sửa ghi chú mã hóa.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.entries.count == 0) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        empty.textLabel.text = @"Chưa có ghi chú riêng tư nào";
        empty.textLabel.textColor = [UIColor secondaryLabelColor];
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    static NSString *cellId = @"ZLModNoteCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    cell.textLabel.text = entry[@"note"] ?: @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Hội thoại: %@", entry[@"threadHash"] ?: @"none"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.entries.count == 0 || (NSUInteger)indexPath.row >= self.entries.count) return;
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *tid = entry[@"threadId"];
    if (tid.length == 0) return;

    ZLModPresentPrivateNoteEditor(self, tid, entry[@"threadHash"], ^(__unused BOOL saved) {
        [self reloadNotes];
    });
}

@end

#pragma mark - 5. Module Status Viewer

@interface ZLModModuleStatusViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *moduleNames;
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *statuses;
@end

@implementation ZLModModuleStatusViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Module Hook Status";
    self.statuses = ZLModAllModuleStatuses();
    self.moduleNames = [[self.statuses allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.moduleNames.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"ZLModStatusCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }
    NSString *name = self.moduleNames[(NSUInteger)indexPath.row];
    NSDictionary *info = self.statuses[name];
    NSString *status = info[@"status"] ?: ZLModModuleStatusNotInstalled;
    NSString *detail = info[@"detail"] ?: @"";

    cell.textLabel.text = [NSString stringWithFormat:@"%@ — %@", name, status];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end

#pragma mark - 6. Redacted Log Viewer

@interface ZLModLogViewerController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *lines;
@end

@implementation ZLModLogViewerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Runtime Logs (Redacted)";
    UIBarButtonItem *copyBtn = [[UIBarButtonItem alloc] initWithTitle:@"Sao chép"
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(copyLogs:)];
    UIBarButtonItem *clearBtn = [[UIBarButtonItem alloc] initWithTitle:@"Xóa"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(clearLogs:)];
    self.navigationItem.rightBarButtonItems = @[clearBtn, copyBtn];
    [self reloadLogs];
}

- (void)reloadLogs {
    self.lines = ZLModReadRecentLogs(200);
    [self.tableView reloadData];
}

- (void)copyLogs:(__unused id)sender {
    NSString *joined = [self.lines componentsJoinedByString:@"\n"];
    [UIPasteboard generalPasteboard].string = joined ?: @"";
    ZLModShowToast(@"Đã sao chép log vào bộ nhớ tạm");
}

- (void)clearLogs:(__unused id)sender {
    ZLModClearLogs();
    [self reloadLogs];
    ZLModShowToast(@"Đã xóa bộ đệm log");
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)MAX(self.lines.count, (NSUInteger)1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return ZLModPrimaryLogPath();
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"ZLModLogLineCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (self.lines.count == 0) {
        cell.textLabel.text = @"Log trống";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        cell.textLabel.text = self.lines[(NSUInteger)indexPath.row];
        cell.textLabel.textColor = [UIColor labelColor];
    }
    return cell;
}

@end

#pragma mark - 7. Main ZLModSettingsViewController

@interface ZLModSettingsViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *model;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISwitch *> *switches;
@end

@implementation ZLModSettingsViewController

+ (instancetype)make {
    ZLModSettingsViewController *vc = [[ZLModSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.title = @"ZLMod Customize";
    return vc;
}

+ (void)pushFrom:(UIViewController *)host {
    ZLModSettingsViewController *dash = [ZLModSettingsViewController make];
    UINavigationController *nav = host.navigationController;
    if (nav) {
        [nav pushViewController:dash animated:YES];
        return;
    }
    UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:dash];
    dash.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:dash
                                                      action:@selector(dismissSelf:)];
    wrapper.modalPresentationStyle = UIModalPresentationFormSheet;
    [host presentViewController:wrapper animated:YES completion:nil];
}

- (void)dismissSelf:(__unused id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.switches = [NSMutableDictionary dictionary];
    [self buildModel];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52.0;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(externalStateDidChange:) name:ZLModConversationPolicyDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(externalStateDidChange:) name:ZLModAccountDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(externalStateDidChange:) name:ZLModThemeDidChangeNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)externalStateDidChange:(__unused NSNotification *)note {
    if (!self.isViewLoaded || !self.view.window) return;
    [self buildModel];
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self buildModel];
    [self.tableView reloadData];
}

- (void)buildModel {
    ZLModThemeManager *themeMgr = [ZLModThemeManager shared];
    NSString *presetLabel = [themeMgr displayNameForPreset:[themeMgr activePresetId]];
    NSString *tintLabel = ([themeMgr customTintHex].length > 0) ? [themeMgr customTintHex] : @"Mặc định";

    NSArray *appearance = @[
        @{ @"title": @"Liquid Glass Tab Bar", @"subtitle": ZLModGlassMaterialDescription(),
           @"key": kZLModGlassTabBar, @"switch": @YES },
        @{ @"title": @"Theme Preset", @"value": presetLabel, @"action": @"theme_preset" },
        @{ @"title": @"Custom Accent Tint (#HEX)", @"value": tintLabel, @"action": @"theme_tint" },
    ];

    NSArray *privacy = @[
        @{ @"title": @"Hide Typing Indicator", @"subtitle": @"Không gửi trạng thái đang nhập (Toàn cục)", @"key": kZLModHideTyping, @"switch": @YES },
        @{ @"title": @"Control Seen Status", @"subtitle": @"Không gửi thông báo đã xem tin nhắn (Toàn cục)", @"key": kZLModHideSeen, @"switch": @YES },
        @{ @"title": @"Control Read Receipts", @"subtitle": @"Không gửi biên nhận đã đọc lên máy chủ", @"key": kZLModHideReadReceipts, @"switch": @YES },
        @{ @"title": @"Disable Tracking & Analytics", @"subtitle": @"Chặn endpoint tracking của Zalo", @"key": kZLModBlockTracking, @"switch": @YES },
        @{ @"title": @"Disable Firebase Collection", @"subtitle": @"Tắt thu thập Firebase Analytics/Performance", @"key": kZLModBlockFirebase, @"switch": @YES },
    ];

    NSUInteger policyCount = [[ZLModConversationPolicyStore shared] customizedCountForCurrentAccount];
    NSArray *perConversation = @[
        @{ @"title": @"Per-Conversation Policies",
           @"value": [NSString stringWithFormat:@"%lu hội thoại", (unsigned long)policyCount],
           @"action": @"conv_policies" },
    ];

    NSUInteger recallCount = [[ZLModAntiRecallStore shared] preservedCountForCurrentAccount];
    NSArray *messaging = @[
        @{ @"title": @"Anti-Recall (Ghost Preview)",
           @"subtitle": @"Giữ bản sao mã hóa cục bộ khi đối phương thu hồi tin nhắn (TTL 14 ngày)",
           @"key": kZLModAntiRecall, @"switch": @YES },
        @{ @"title": @"Ghost Preview History",
           @"value": [NSString stringWithFormat:@"%lu bản ghi", (unsigned long)recallCount],
           @"action": @"antirecall_history" },
    ];

    NSTimeInterval delaySec = [[ZLModDelaySendManager shared] delayDuration];
    NSUInteger quickCount = [[ZLModQuickReplyStore shared] quickReplies].count;
    NSUInteger notesCount = [[ZLModPrivateNotesStore shared] allEntriesForCurrentAccount].count;
    NSArray *utilities = @[
        @{ @"title": @"Delay Send Undo",
           @"subtitle": @"Hoãn gửi tin nhắn kèm thanh Hủy gửi trước khi phát đi",
           @"key": kZLModDelaySend, @"switch": @YES },
        @{ @"title": @"Delay Duration",
           @"value": [NSString stringWithFormat:@"%.0f giây", delaySec],
           @"action": @"delay_duration" },
        @{ @"title": @"Quick Reply Templates",
           @"value": [NSString stringWithFormat:@"%lu mẫu", (unsigned long)quickCount],
           @"action": @"quick_replies" },
        @{ @"title": @"Encrypted Private Notes",
           @"value": [NSString stringWithFormat:@"%lu ghi chú", (unsigned long)notesCount],
           @"action": @"private_notes" },
    ];

    NSArray *ads = @[
        @{ @"title": @"Hide Ads", @"subtitle": @"Ẩn thành phần quảng cáo trong giao diện", @"key": kZLModHideAds, @"switch": @YES },
        @{ @"title": @"Block Ad Requests", @"subtitle": @"Chặn endpoint quảng cáo (zpads, ads api)", @"key": kZLModBlockAdRequests, @"switch": @YES },
    ];

    NSArray *features = @[
        @{ @"title": @"Profile Music", @"subtitle": @"Khôi phục nhạc trang cá nhân", @"key": kZLModRestoreProfileMusic, @"switch": @YES },
        @{ @"title": @"Google Drive Backup", @"subtitle": @"Khôi phục mục sao lưu Google Drive", @"key": kZLModRestoreGDrive, @"switch": @YES },
        @{ @"title": @"More Tab", @"subtitle": @"Khôi phục tab More (enable_tabmore)", @"key": kZLModRestoreMoreTab, @"switch": @YES },
    ];

    NSDictionary *statuses = ZLModAllModuleStatuses();
    NSUInteger installedModules = 0;
    for (NSString *m in statuses) {
        if ([statuses[m][@"status"] isEqualToString:ZLModModuleStatusHookInstalled]) {
            installedModules++;
        }
    }
    NSString *scope = ZLModCurrentAccountScope() ?: @"unidentified (fail-closed)";
    NSArray *diagnostics = @[
        @{ @"title": @"Module Hook Status",
           @"value": [NSString stringWithFormat:@"%lu/%lu active", (unsigned long)installedModules, (unsigned long)statuses.count],
           @"action": @"module_status" },
        @{ @"title": @"Runtime Log Viewer",
           @"value": [NSString stringWithFormat:@"%lu dòng", (unsigned long)ZLModReadRecentLogs(200).count],
           @"action": @"log_viewer" },
        @{ @"title": @"Active Account Scope", @"value": scope },
        @{ @"title": @"Reset All ZLMod Settings", @"value": @"Đặt lại", @"action": @"reset_all" },
    ];

    NSArray *about = @[
        @{ @"title": @"Version", @"value": [NSString stringWithFormat:@"%@ (%@)", ZLMOD_VERSION, ZLMOD_BUILD] },
        @{ @"title": @"Zalo", @"value": [ZLModCompatibility hostVersion] },
        @{ @"title": @"Compatibility", @"value": [ZLModCompatibility supportReason] },
        @{ @"title": @"Settings anchor", @"value": [ZLModCompatibility anchorExists:@"SettingUI40TableViewController"] ? @"✔︎ SettingUI40TableViewController" : @"—" },
        @{ @"title": @"Tab bar anchor", @"value": [ZLModCompatibility anchorExists:@"ZaloTabBarViewController"] ? @"✔︎ ZaloTabBarViewController" : @"—" },
        @{ @"title": @"Inbox menu anchor", @"value": [ZLModCompatibility anchorExists:@"InboxContextMenuManager"] ? @"✔︎ InboxContextMenuManager" : @"—" },
        @{ @"title": @"Chat VC anchor", @"value": [ZLModCompatibility anchorExists:@"BaseChatTVC"] ? @"✔︎ BaseChatTVC" : @"—" },
        @{ @"title": @"Anti-Recall anchor", @"value": [ZLModCompatibility anchorExists:@"ConversationModel"] ? @"✔︎ ConversationModel" : @"—" },
    ];

    self.model = @[
        @{ @"header": @"Appearance & Theme", @"rows": appearance },
        @{ @"header": @"Privacy (Global)", @"rows": privacy },
        @{ @"header": @"Per-Conversation Privacy & Unread", @"rows": perConversation },
        @{ @"header": @"Messaging & Anti-Recall", @"rows": messaging },
        @{ @"header": @"Utilities", @"rows": utilities },
        @{ @"header": @"Ad Blocking", @"rows": ads },
        @{ @"header": @"Feature Restoration", @"rows": features },
        @{ @"header": @"Diagnostics & Maintenance", @"rows": diagnostics },
        @{ @"header": @"About ZLMod", @"rows": about },
    ];
}

#pragma mark - Table Data Source & Delegate

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.model.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self.model[(NSUInteger)section][@"rows"] count];
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.model[(NSUInteger)section][@"header"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.model[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    NSString *key = row[@"key"];
    NSString *action = row[@"action"];

    if (key) {
        static NSString *cellId = @"ZLModSwitchCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = row[@"subtitle"];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 2;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *sw = self.switches[key];
        if (!sw) {
            sw = [[UISwitch alloc] init];
            objc_setAssociatedObject(sw, "zlmod.pref.key", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            self.switches[key] = sw;
        }
        sw.on = [[ZLModPreferences shared] boolForKey:key];
        cell.accessoryView = sw;
        return cell;
    }

    if (action) {
        static NSString *actionId = @"ZLModActionCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:actionId];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:actionId];
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = row[@"value"];
        if ([action isEqualToString:@"reset_all"]) {
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.textColor = [UIColor labelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    static NSString *infoId = @"ZLModInfoCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:infoId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:infoId];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = row[@"value"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.model[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    NSString *action = row[@"action"];
    if (!action) return;

    if ([action isEqualToString:@"theme_preset"]) {
        [self presentThemePresetPickerFromIndexPath:indexPath];
    } else if ([action isEqualToString:@"theme_tint"]) {
        [self presentThemeTintEditor];
    } else if ([action isEqualToString:@"conv_policies"]) {
        ZLModConversationPoliciesViewController *vc = [[ZLModConversationPoliciesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"antirecall_history"]) {
        ZLModAntiRecallHistoryViewController *vc = [[ZLModAntiRecallHistoryViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"delay_duration"]) {
        [self presentDelayDurationPickerFromIndexPath:indexPath];
    } else if ([action isEqualToString:@"quick_replies"]) {
        ZLModQuickRepliesViewController *vc = [[ZLModQuickRepliesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"private_notes"]) {
        ZLModPrivateNotesViewController *vc = [[ZLModPrivateNotesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"module_status"]) {
        ZLModModuleStatusViewController *vc = [[ZLModModuleStatusViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"log_viewer"]) {
        ZLModLogViewerController *vc = [[ZLModLogViewerController alloc] initWithStyle:UITableViewStylePlain];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"reset_all"]) {
        [self presentResetAllConfirmation];
    }
}

#pragma mark - Action sheets & dialogs

- (void)presentThemePresetPickerFromIndexPath:(NSIndexPath *)indexPath {
    ZLModThemeManager *mgr = [ZLModThemeManager shared];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Chọn Theme Preset"
                                                                   message:@"Mặc định hệ thống sẽ giữ nguyên hoàn toàn giao diện gốc của Zalo."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *presetId in [mgr availablePresetIds]) {
        NSString *title = [mgr displayNameForPreset:presetId];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [mgr applyPresetNamed:presetId];
            [self buildModel];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *c = [self.tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = c ?: self.view;
        sheet.popoverPresentationController.sourceRect = c ? c.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentThemeTintEditor {
    ZLModThemeManager *mgr = [ZLModThemeManager shared];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Màu nhấn tùy chỉnh (#RRGGBB)"
                                                                   message:@"Để trống để dùng màu mặc định của Preset hoặc Zalo."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Ví dụ: #0068FF";
        tf.text = [mgr customTintHex];
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Áp dụng"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *hex = alert.textFields.firstObject.text ?: @"";
        [mgr applyCustomTintHex:hex];
        [self buildModel];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentDelayDurationPickerFromIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Thời gian hoãn gửi"
                                                                   message:@"Chọn khoảng thời gian hiển thị nút Hủy gửi trước khi tin nhắn được gửi đi."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *sec in @[@1, @3, @5, @8, @10]) {
        NSString *label = [NSString stringWithFormat:@"%ld giây", (long)sec.integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [[ZLModDelaySendManager shared] setDelayDuration:sec.doubleValue];
            [self buildModel];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *c = [self.tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = c ?: self.view;
        sheet.popoverPresentationController.sourceRect = c ? c.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentResetAllConfirmation {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đặt lại toàn bộ ZLMod?"
                                                                   message:@"Tắt mọi công tắc tính năng, khôi phục giao diện gốc của Zalo và xóa chính sách hội thoại tùy chỉnh."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đặt lại tất cả"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModDelaySendManager shared] cancelAllPendingSends];
        [[ZLModPreferences shared] resetAllPreferences];
        [[ZLModThemeManager shared] resetTheme];
        [[ZLModConversationPolicyStore shared] resetAllPolicies];
        [self buildModel];
        [self.tableView reloadData];
        ZLModShowToast(@"Đã đặt lại toàn bộ cài đặt ZLMod");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, "zlmod.pref.key");
    if (!key) return;
    [[ZLModPreferences shared] setBool:sw.on forKey:key];
}

@end
