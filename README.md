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

- `supabase/migrations/` ghi lại cấu trúc tám bảng cốt lõi đã áp dụng trên Supabase B, kho ảnh riêng tư và quyền đọc theo lớp được phân công. Quyền quản trị xem toàn bộ lớp yêu cầu phiên có mức xác thực `aal2`.
- `supabase/functions/teacher-accounts/` giữ mã dịch vụ tài khoản của ứng dụng cũ để hoàn thiện luồng giáo viên trên project B. Dịch vụ cần được cấu hình và kiểm thử trước khi dùng.
- Để chuyển toàn bộ lịch sử, cần sao chép có kiểm soát tài khoản liên quan, hồ sơ, lớp, danh sách học sinh, buổi điểm danh, bản ghi, lịch sử thay đổi và tệp của bucket riêng tư. Giữ nguyên ID và đối chiếu số bản ghi ở hai đầu. Đối chiếu phân công của các lớp thiếu thông tin trước khi mở quyền cho giáo viên.
- Các migration kèm theo là nền tảng đã kiểm tra quyền đọc. Luồng ghi điểm danh và các RPC nghiệp vụ còn thiếu cần được hoàn thiện cùng dữ liệu thật, Auth, ảnh minh chứng và phân quyền nghiệp vụ trước khi dùng.

Mã nguồn gốc lấy từ nhánh `codex/brian-attendance-standalone`, commit `79907c78616c88e605d6894d17cf05e6c4f077f9`.
