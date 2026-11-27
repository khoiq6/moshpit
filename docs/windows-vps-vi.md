# Windows VPS trong Moshpit (vi-windows-rdp)

## Windows SSH (trực tiếp)
Chọn dấu + → Windows SSH (PowerShell / CMD). Mặc định dùng SSH cổng 22, không Mosh, không tmux/herdr. Sửa username nếu tài khoản không phải Administrator. Moshpit dùng lại xác thực SSH và kiểm tra khóa máy chủ hiện có. Các hook Codex trên Windows chưa được chuyển từ shell POSIX sang PowerShell; terminal là tính năng chính được cung cấp ở đây.

Trên Windows Server, chạy PowerShell với quyền quản trị nếu OpenSSH Server chưa có:
```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
```
Kiểm tra firewall, ưu tiên chỉ cho IP/VPN được phép truy cập. Xem https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse và https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration.

## Windows Remote Desktop
Đây là RDP qua Apache Guacamole 1.6+, không phải client native TCP 3389. Cài gateway tại máy Linux bạn quản lý theo https://guacamole.apache.org/doc/gug/guacamole-docker.html. Bật Remote Desktop trên Windows Server/Pro, dùng NLA, giới hạn firewall RDP cho IP riêng của gateway; dùng chứng chỉ đáng tin cậy, không tắt xác thực chứng chỉ. Không mở cổng guacd 4822 ra Internet. Reverse proxy HTTPS với WebSocket theo https://guacamole.apache.org/doc/gug/reverse-proxy.html.

Trong gateway tạo kết nối RDP với địa chỉ Windows, cổng 3389, user được phép đăng nhập. Moshpit: + → Màn hình Windows → nhập URL HTTPS gateway. Đăng nhập và chọn kết nối. Không đưa thông tin đăng nhập vào URL. WebKit dùng data store không lưu lâu dài; khi đóng màn hình phải đăng nhập lại nếu gateway yêu cầu. Gateway có thể giữ phiên Windows tùy thiết lập của quản trị viên.

Cảm ứng tuyệt đối / chuột tương đối: vuốt từ mép trái để mở menu Guacamole. Chọn mode phù hợp, dùng bàn phím ảo hoặc Bluetooth. Hỗ trợ chụm để zoom và toàn màn hình. Cử chỉ và chuột Bluetooth cần kiểm thử iPhone thực tế.

## Hiệu năng
Tạo ba kết nối cùng host trên Guacamole (không cần thêm thông tin xác thực trong app). Cấu hình thực tế ở gateway:
| Tham số RDP | Tốc độ | Cân bằng | Chất lượng |
| --- | --- | --- | --- |
| width × height | 1280 × 720 | 1600 × 900 | 1920 × 1080 |
| disable-gfx | false | false | false |
| disable-audio | true | true | false |
| enable-wallpaper | false | false | false |
| enable-theming | false | false | true |
| enable-font-smoothing | false | true | true |
| enable-full-window-drag | false | false | false |
| enable-desktop-composition | false | false | false |
| enable-menu-animations | false | false | false |
| enable-touch | true | true | true |

Không cưỡng ép color-depth thấp khi GFX được bật. Chọn cấu hình ở gateway trước khi mở phiên. Nếu resize động được máy chủ hỗ trợ, thử resize-method=display-update; không bật nếu muốn giữ giới hạn độ phân giải cố định. Không bật ignore-cert để tránh lỗi kết nối.

Ưu tiên WebSocket thay HTTP polling, gateway gần Windows, giảm độ phân giải khi mạng yếu. Không có FPS cố định hay tự động chuyển profile trong bản này. Không quảng cáo 60 FPS khi chưa đo. Đo RTT iPhone–gateway, gateway–Windows, FPS thực tế và độ trễ input trên Wi-Fi/5G. Xem https://guacamole.apache.org/doc/gug/configuring-guacamole.html và https://guacamole.apache.org/doc/gug/using-guacamole.html.

## Phạm vi
- Có giao diện chọn Windows SSH, phiên RDP gateway trong app, HTTPS cùng origin, reconnect thủ công và toàn màn hình.
- Chưa tích hợp FreeRDP/IronRDP native; chưa chạy kiểm thử kết nối RDP thực tế, chưa đo FPS, chưa có bộ điều khiển tự động điều chỉnh bitrate hay tái kết nối RDP tự động.
- Phần UI gateway dùng ngôn ngữ của Guacamole; chuỗi Moshpit mới có tiếng Việt và tiếng Anh.
