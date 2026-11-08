# ZLMod — Zalo native customization (iOS)

Dylib độc lập cho các build Zalo được allowlist chính xác (`261002/261002802`
và `261101/261101802`; bundle `vn.com.vng.zingalo` hoặc
`vn.com.vng.zingalo2`, arm64, iOS 15.1+):
tùy chỉnh giao diện, quyền riêng tư toàn cục & theo từng cuộc trò chuyện,
Anti-Recall (Ghost Preview) mã hóa cục bộ, tiện ích nhắn tin, chặn quảng cáo và
khôi phục tính năng — tích hợp theo phong cách native, mặc định tắt hoàn toàn
khi mới cài đặt.

## Thành phần (Build 5)

| Module | Vai trò |
|---|---|
| `ZLModCore` | khởi tạo, cô lập từng module, ring-buffer + file log có redaction, theo dõi phiên đăng nhập/đăng xuất |
| `ZLModCompatibility` | nhận diện host + exact version/build gate + kiểm tra anchors |
| `ZLModPreferences` | lưu cấu hình (suite riêng + mirror App Group `group.zsettings.vn.com.vng.zingalo` + khôi phục nguyên trạng) |
| `ZLModHookEngine` | discovery runtime, thay instance/class method có kiểm chứng arity/encoding + đọc thuộc tính an toàn ABI |
| `ZLModCryptoStore` | hộp lưu trữ mã hóa AES-256-CBC + HMAC-SHA256 dùng khóa trong iOS Keychain + định danh `accountScope` (fail-closed) |
| `ZLModPolicyStore` | theo dõi ngữ cảnh chat đang mở + lưu chính sách Seen/Typing/Unread theo từng hội thoại gắn với `accountScope` |
| `ZLModURIFilter` | chặn endpoint tracking/ad trong tiến trình (`NSURLProtocol`) |
| `ZLModPrivacy` | ẩn typing, kiểm soát seen/read receipts (toàn cục + từng cuộc trò chuyện), tắt Firebase collection |
| `ZLModConversationMenu` | menu nhấn giữ hội thoại (`InboxContextMenuManager`) + chấm xanh chưa đọc trên `UXInboxMessageCell` & `ChatListItemCell` |
| `ZLModAntiRecall` | lưu cục bộ có mã hóa bản sao tin nhắn bị thu hồi (Ghost Preview, TTL 14 ngày, nhãn bản sao cục bộ rõ ràng) |
| `ZLModUtilities` | ghi chú riêng tư mã hóa theo hội thoại, mẫu trả lời nhanh (chỉ điền vào ô nhập), hoãn gửi tin nhắn kèm nút Hủy gửi |
| `ZLModTheme` | preset giao diện (`classic_blue`, `dark_oled`, `pure_black`, `ocean_teal`) + màu nhấn `#HEX` có chụp & khôi phục baseline |
| `ZLModAds` | chặn request quảng cáo + vô hiệu hóa view quảng cáo |
| `ZLModFeatures` | khôi phục Profile Music, Google Drive Backup, More Tab |
| `ZLModSettings` | hàng "ZLMod Customize" (clone cell gốc) + điều hướng native |
| `ZLModUI` | bảng điều khiển chính + 6 màn hình quản lý và chẩn đoán chi tiết |
| `ZLModGlass` | tab bar material (Liquid Glass khi runtime có `UIGlassEffect`, fallback blur hệ thống) |

## Tính năng chính

**ZLMod Customize** — hàng settings được clone từ cell object thật của Zalo
(`BasicSettingCellV2Object` của "Tài khoản và bảo mật", key `00Zh8W`), chèn ngay
phía trên "Tài khoản và bảo mật", điều hướng bằng navigation controller gốc.

**Privacy (Toàn cục & Theo từng cuộc trò chuyện)** — ẩn đang nhập (`sendTypingWithType:toUserId:messageType:isE2eeChat:` và `+sendStatusTyping:...`), kiểm soát trạng thái đã xem và biên nhận đã đọc (bao gồm lọc danh sách `sendSeenLastMessageWithThreadIds:withMessageType:`), chặn tracking endpoint và tắt thu thập Firebase. Nhấn giữ một hội thoại bất kỳ trong danh sách tin nhắn để bật/tắt riêng cho cuộc trò chuyện đó.

**Conversation Menu & Local Unread** — tích hợp trực tiếp vào `InboxContextMenuManager` với 4 tác vụ nhanh: bật/tắt Ẩn đã xem, bật/tắt Ẩn đang nhập, Đánh dấu chưa đọc (hiển thị chấm xanh `#0068FF` trên `UXInboxMessageCell` và `ChatListItemCell` mà không gửi gói tin lên máy chủ), và mở Ghi chú riêng tư.

**Anti-Recall (Ghost Preview)** — khi bật, lưu bản sao mã hóa AES-256-CBC + HMAC-SHA256 kèm ràng buộc metadata `(accountScope, globalId, clientId, threadId, timestamp)` và thời hạn tự xóa 14 ngày. Không bao giờ ghi đè cơ sở dữ liệu gốc của Zalo; hiển thị rõ tiền tố `[ZLMod Bản sao cục bộ — tin nhắn gốc đã thu hồi]`.

**Utilities** —
- **Delay Send Undo:** máy trạng thái 5 bước (`Pending`, `Cancelled`, `Dispatching`, `Dispatched`, `Failed`) trên `ZAChatSendingManager -sendChat:checkUpload:`, hiển thị thanh đếm ngược kèm nút **Hủy gửi** (`1–10s`), tự động hủy an toàn khi ứng dụng xuống nền hoặc đổi tài khoản.
- **Quick Reply Templates:** quản lý mẫu câu trả lời nhanh và chèn vào thanh nhập của `BaseChatTVC` (`-fillChatBarWithText:`) hoặc ô nhập đang mở — không bao giờ tự động gửi.
- **Encrypted Private Notes:** ghi chú riêng tư mã hóa cục bộ cho từng cuộc trò chuyện, tách biệt theo tài khoản.

**Appearance & Theme** — Liquid Glass Tab Bar và bộ Theme Preset / Custom Accent Tint (`#RRGGBB`) tùy chọn; lưu trạng thái gốc của cửa sổ/thanh điều hướng trước khi áp dụng để khôi phục sạch sẽ ngay khi tắt.

## Build

```bash
make          # → build/libZLMod.dylib (macOS + Xcode 26 SDK)
make gates    # kiểm tra artifact: arm64, deps, install_name, minos, UIGlassEffect, codesign
```

CI: GitHub Actions `macos-26`, đóng gói `ZLMod-<version>.zip` + SHA-256 + report,
publish Pre-release khi push tag `build-*` (hiện tại **Build 5** / `build-5`).

## Kiểm chứng anchors

Mọi selector/class/key/URL dùng trong code đều nằm trong
`Scripts/anchors.txt` và được đối chiếu ngược với binary:

```bash
ZLMOD_IPA_DUMP=<dump-dir> ./Scripts/anchors-verify.sh
# → anchors: 84 verified, 0 missing
```

Dump dir cần: `objc_methname.txt`, `objc_classname.txt`, `zalo.strings`
(xem `docs/IPA-ANALYSIS.md` để biết cách tạo).

## Đóng gói IPA no-jailbreak

ZLMod có packager cho IPA đã decrypt (`cryptid=0`). Packager nhúng
`build/libZLMod.dylib`, thêm `LC_LOAD_DYLIB @rpath/libZLMod.dylib`, remap bundle
ID/extension và tạo IPA unsigned; bước ký/sideload vẫn do công cụ ký của bạn xử
lý.

```bash
python Packaging/package_ipa.py \
  --input /path/to/Zalo-decrypted.ipa \
  --output /path/to/Zalo-ZLMod-Unsigned.ipa \
  --bundle-id vn.com.vng.zingalo2
```

Bundle ID phải tồn tại trong `Resources/compatibility.json`.

Kiểm tra nhanh IPA (read-only, xác minh `cryptid=0`, compatibility và load commands):

```bash
python Packaging/ipa_preflight.py /path/to/Zalo-decrypted.ipa --require-unencrypted-main --require-compatible
```

## Portable tests

```bash
python -m unittest discover -s Tests -p "test_*.py" -v
python Scripts/project_gate.py .
```

## Không triển khai (có lý do kỹ thuật & an toàn)

- **Original Photo Default** — phụ thuộc pipeline nén/upload đa nhánh của từng luồng picker; chưa có bằng chứng an toàn trên cả hai build.
- **Unlock ZCloud Premium / Paid Entitlements** — quyền lợi do server quyết định; can thiệp phía client là giả tạo và vi phạm giới hạn dự án.
- **Fake admin/owner nhóm** — dữ liệu server-authoritative; chỉ gây hiển thị sai và rủi ro khóa tài khoản.
- **Video transcode bypass / Upload-limit override / Server TTL override** — phụ thuộc xác thực máy chủ và định dạng luồng nhận.
- **Editable `rules.json` hooks / Chat head nổi** — rủi ro mất an toàn chữ ký ABI Objective-C hoặc độ phức tạp cửa sổ không cần thiết.

## License

MIT cho source của dự án. Ý tưởng tính năng tham khảo từ ZaloXposed (AGPL-3.0) —
**clean-room**: không sao chép code, không sao chép matcher/constant table.
