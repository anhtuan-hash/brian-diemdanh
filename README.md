# Brian Điểm danh

Ứng dụng Điểm danh tách từ Brian English Studio. Repo có điểm vào, bộ phụ thuộc, cấu hình Vercel và các migration riêng. Mã nguồn giữ giao diện điểm danh lớp, lịch sử, hồ sơ chuyên cần và xuất báo cáo.

## Chạy và build

Dùng Node.js 22. Sao chép `.env.example` sang `.env.local` để cấu hình Supabase nếu cần chạy màn hình đăng nhập. Điền khóa publishable hoặc anon của project Điểm danh B vào `VITE_ATTENDANCE_SUPABASE_ANON_KEY`.

```sh
npm ci
npm run dev
npm run build
```

Trên Vercel, để Root Directory ở thư mục gốc repo. Các thiết lập build đã nằm trong `vercel.json`. Cấu hình hai biến từ `.env.example` sau khi Supabase B đã sẵn sàng cho người dùng.

## Supabase và dữ liệu

- `supabase/migrations/` ghi lại cấu trúc đã áp dụng trên Supabase B, gồm tám bảng cốt lõi và mười bảng lưu trữ, bổ sung và cấu hình. Các bảng mới được giữ riêng tư. Quyền đọc bảng cốt lõi dựa trên lớp được phân công. Quyền quản trị xem toàn bộ lớp yêu cầu phiên có mức xác thực `aal2`.
- `supabase/functions/teacher-accounts/` giữ mã dịch vụ tài khoản của ứng dụng cũ để hoàn thiện luồng giáo viên trên project B. Dịch vụ cần được cấu hình và kiểm thử trước khi dùng.
- Các migration kèm theo là nền tảng đã kiểm tra quyền đọc. Luồng ghi điểm danh và các RPC nghiệp vụ còn thiếu cần được hoàn thiện cùng dữ liệu thật, Auth, ảnh minh chứng và phân quyền nghiệp vụ trước khi dùng.

### Chuyển dữ liệu giữa hai dự án

Chạy `scripts/migrate-attendance.mjs` trên máy của quản trị viên với Node.js 22+, `npm ci` và PostgreSQL client (`psql` 17+). Lấy URI kết nối **Session pooler** (cổng 5432) trong mục **Connect** của từng dự án Supabase, điền mật khẩu cơ sở dữ liệu đã mã hóa URL. Nếu cần chỉ định CA, tải chứng chỉ trong **Database Settings** rồi đặt đường dẫn tuyệt đối qua `ATTENDANCE_SOURCE_DB_URL_CA` và `ATTENDANCE_TARGET_DB_URL_CA`. Script luôn xác thực TLS bằng `verify-full`.

1. Đặt `ATTENDANCE_SOURCE_DB_URL` cho project `xpkbgqdlfonsinriggmj` và `ATTENDANCE_TARGET_DB_URL` cho project `btgxeaakwjtlfvgiexzp` trong môi trường Terminal cục bộ. Giữ các giá trị này ngoài Git và biến môi trường frontend.
2. Chạy `node scripts/migrate-attendance.mjs` để đối chiếu số lượng giữa nguồn và đích. Chế độ này chỉ đọc tổng số.
3. Khi chốt dữ liệu nguồn, tạm ngưng ghi điểm danh trong thời gian sao chép. Đặt `ATTENDANCE_SOURCE_STORAGE_KEY` và `ATTENDANCE_TARGET_STORAGE_KEY` bằng khóa máy chủ của từng project, rồi chạy `node scripts/migrate-attendance.mjs --apply`. Script xác minh ảnh bằng SHA-256, giữ nguyên ID và kiểm tra nội dung từng bảng trước khi commit giao dịch. Đích phải đang trống hoặc chứa đúng bản sao nguồn. Có thể chạy lại khi sao chép ảnh bị gián đoạn.
4. Kiểm tra OAuth và SMTP nếu tài khoản cần các dịch vụ này. Người dùng đăng nhập lại và quản trị viên đăng ký lại MFA trên project B. Script chuyển thông tin đăng nhập cần cho các tài khoản nằm trong phạm vi hồ sơ và vai trò hệ thống, giữ hash mật khẩu và danh tính đăng nhập. Phiên, token khôi phục đang hoạt động và bí mật MFA thuộc về project nguồn.

Mã nguồn gốc lấy từ nhánh `codex/brian-attendance-standalone`, commit `79907c78616c88e605d6894d17cf05e6c4f077f9`.
