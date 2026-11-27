# Gateway RDP tùy chọn

Cần Linux có Docker Compose và openssl. Chạy `bash setup.sh`. Dịch vụ chỉ bind 127.0.0.1:8080, không mở database/guacd ra Internet. Không chạy nếu cổng 8080 đang được dùng bởi dịch vụ khác.

Từ máy quản trị, mở SSH tunnel đến máy Linux: `ssh -L 8080:127.0.0.1:8080 user@gateway`. Truy cập http://127.0.0.1:8080/guacamole/ qua tunnel để đăng nhập ban đầu (guacadmin / guacadmin); đổi ngay mật khẩu mặc định, tạo tài khoản riêng ít quyền và thiết lập kết nối Windows. Không publish trước bước này. Dùng RDP NLA và xác minh chứng chỉ máy Windows. Sau đó cấu hình reverse proxy HTTPS và WebSocket: https://guacamole.apache.org/doc/gug/reverse-proxy.html. Nhập địa chỉ HTTPS đó trong Moshpit.

Các profile hiệu năng và thao tác cảm ứng nằm trong [hướng dẫn Windows VPS](../../docs/windows-vps-vi.md). Không tự động triển khai lên VPS hiện có. Kiểm tra bản vá bảo mật mới trước khi đưa dịch vụ lên Internet; ưu tiên mạng VPN riêng.

.env và initdb.sql được tạo cục bộ; không commit. Không xóa volume database để nâng cấp; sao lưu và làm theo hướng dẫn nâng cấp schema của Apache Guacamole.
