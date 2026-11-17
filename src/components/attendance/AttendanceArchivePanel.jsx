import React, { useMemo, useState } from 'react';
import AttendanceEditorialHeading from './AttendanceEditorialHeading.jsx';
import { AttendanceUiIcon } from './AttendanceWorkspaceUI.jsx';

const archivedAtFormatter = new Intl.DateTimeFormat('vi-VN', {
  dateStyle: 'short', timeStyle: 'short', timeZone: 'Asia/Ho_Chi_Minh',
});

function formatDate(value) {
  const match = String(value || '').match(/^(\d{4})-(\d{2})-(\d{2})/);
  return match ? `${match[3]}/${match[2]}/${match[1]}` : '—';
}

function formatDateTime(value) {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : archivedAtFormatter.format(date);
}

function fold(value) {
  return String(value ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/đ/g, 'd').trim();
}

const REQUEST_LABELS = {
  pending: 'Đang chờ Admin duyệt',
  approved: 'Đã duyệt · chờ hoàn tất xóa',
  rejected: 'Đã từ chối yêu cầu xóa',
};

function ArchiveSource({ item }) {
  if (item.archive_kind !== 'class') {
    return <small>{item.source_type === 'supplemental' ? 'Học bổ sung' : 'Điểm danh lớp'}{item.subject ? ` · ${item.subject}` : ''}</small>;
  }
  const classType = { remedial: 'Phụ đạo', gifted: 'Bồi dưỡng' }[item.class_type];
  const description = [classType, item.subject, item.grade_level && `Khối ${item.grade_level}`, item.school_year].filter(Boolean);
  return (
    <details className="ae-archive__class-detail">
      <summary>Lớp học · Chi tiết</summary>
      {description.length > 0 && <span>{description.join(' · ')}</span>}
      <span>{item.member_count ?? 0} học sinh · {item.teacher_count ?? 0} giáo viên</span>
      <span>{item.session_count ?? 0} buổi điểm danh · {item.record_count ?? 0} bản ghi</span>
      {item.archived_by_name && <span>Người lưu trữ: {item.archived_by_name}</span>}
    </details>
  );
}

export default function AttendanceArchivePanel({
  items = [],
  classItems = [],
  loading = false,
  busy = false,
  isAdmin = false,
  canManageClasses = false,
  onRefresh,
  onRestore,
  onRequestDelete,
  onApproveDelete,
  onRejectDelete,
  onRestoreClass,
  onRequestDeleteClass,
  onApproveDeleteClass,
  onRejectDeleteClass,
}) {
  const [query, setQuery] = useState('');
  const [source, setSource] = useState('all');
  const [requestStatus, setRequestStatus] = useState('all');

  const combined = useMemo(() => [
    ...items.map((item) => ({ ...item, archive_kind: 'attendance' })),
    ...classItems.map((item) => ({ ...item, archive_kind: 'class', source_type: 'class' })),
  ].sort((a, b) => (Date.parse(b.archived_at) || 0) - (Date.parse(a.archived_at) || 0)), [items, classItems]);

  const searchTerm = fold(query);
  const filtered = combined.filter((item) => {
    if (source !== 'all' && item.source_type !== source) return false;
    if (requestStatus !== 'all' && (item.delete_request_status || 'none') !== requestStatus) return false;
    return !searchTerm || fold(`${item.class_name} ${item.subject} ${item.teacher_name} ${item.archived_by_name} ${item.grade_level} ${item.school_year}`).includes(searchTerm);
  });
  const pendingCount = combined.filter((item) => item.delete_request_status === 'pending').length;
  const approvedCount = combined.filter((item) => item.delete_request_status === 'approved').length;
  const metrics = [
    { label: 'Đang lưu trữ', value: loading ? null : combined.length },
    ...(isAdmin ? [{ label: 'Chờ duyệt', value: loading ? null : pendingCount }] : []),
    ...(isAdmin && approvedCount > 0 ? [{ label: 'Chờ hoàn tất', value: approvedCount }] : []),
  ];

  return (
    <section className="ae-archive" aria-label="Kho lưu trữ điểm danh" aria-busy={loading}>
      <AttendanceEditorialHeading title="Kho lưu trữ" className="ae-heading--archive" metrics={metrics} />

      <div className="ae-archive__filters ae-field-row" data-bes-keep-search="true">
        <label>
          <span>Tìm trong kho</span>
          <span className="ae-search">
            <AttendanceUiIcon name="search" size={21} />
            <input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Tên lớp, môn, giáo viên…" />
          </span>
        </label>
        <label>
          <span>Nguồn</span>
          <select value={source} onChange={(event) => setSource(event.target.value)}>
            <option value="all">Tất cả</option><option value="class">Lớp học</option>
            <option value="extra">Phụ đạo / Bồi dưỡng</option><option value="supplemental">Học bổ sung</option>
          </select>
        </label>
        <label>
          <span>Trạng thái xóa</span>
          <select value={requestStatus} onChange={(event) => setRequestStatus(event.target.value)}>
            <option value="all">Tất cả</option><option value="none">Chưa yêu cầu</option><option value="pending">Chờ duyệt</option>
            <option value="approved">Chờ hoàn tất</option><option value="rejected">Đã từ chối</option>
          </select>
        </label>
        <button type="button" className="ae-button" disabled={busy || loading} onClick={onRefresh}>Làm mới</button>
      </div>

      {loading && <p role="status" className="ae-message">Đang tải Kho lưu trữ…</p>}
      {!loading && filtered.length === 0 && (
        <div className="ae-archive__empty" role="status">
          <span aria-hidden="true"><AttendanceUiIcon name={combined.length ? 'search' : 'archive'} size={30} /></span>
          <div>
            <h2>{combined.length ? 'Không có mục phù hợp' : 'Kho lưu trữ đang trống'}</h2>
            <p>{combined.length ? 'Thay đổi từ khóa hoặc bộ lọc để xem kết quả.' : 'Các lớp và buổi học được lưu trữ sẽ hiển thị tại đây.'}</p>
          </div>
        </div>
      )}

      {!loading && filtered.length > 0 && (
        <div className="ae-table-scroll" tabIndex={0} role="region" aria-label="Danh sách dữ liệu lưu trữ">
          <table className="ae-table ae-archive__table">
            <thead>
              <tr><th scope="col">Lớp / Nguồn</th><th scope="col">Ngày học</th><th scope="col">Giáo viên</th>
                <th scope="col">Lưu trữ lúc</th><th scope="col">Trạng thái</th><th scope="col">Thao tác</th></tr>
            </thead>
            <tbody>{filtered.map((item) => {
              const status = item.delete_request_status;
              const pending = status === 'pending';
              const approved = status === 'approved';
              const isClass = item.archive_kind === 'class';
              const mayRestoreOrRequest = (!isClass || canManageClasses) && !pending && !approved;
              const restore = isClass ? onRestoreClass : onRestore;
              const requestDelete = isClass ? onRequestDeleteClass : onRequestDelete;
              const approveDelete = isClass ? onApproveDeleteClass : onApproveDelete;
              const rejectDelete = isClass ? onRejectDeleteClass : onRejectDelete;

              return <tr key={`${item.archive_kind}:${item.archive_id}`}>
                <th scope="row"><strong>{item.class_name || (isClass ? 'Lớp học' : 'Buổi điểm danh')}</strong><ArchiveSource item={item} /></th>
                <td>{formatDate(item.attendance_date)}</td>
                <td>{item.teacher_name || '—'}</td>
                <td>{formatDateTime(item.archived_at)}</td>
                <td>
                  <strong className={pending ? 'ae-archive__pending' : undefined}>{REQUEST_LABELS[status] || 'Đang lưu trữ'}</strong>
                  {pending && item.delete_request_reason && <small>Lý do: {item.delete_request_reason}</small>}
                  {(approved || status === 'rejected') && item.delete_review_note && <small>Phản hồi Admin: {item.delete_review_note}</small>}
                </td>
                <td>
                  <div className="ae-archive__actions">
                    {mayRestoreOrRequest && <>
                      <button type="button" className="ae-button" disabled={busy} onClick={() => restore?.(item)}>Khôi phục</button>
                      <button type="button" className="ae-button ae-button--danger" disabled={busy} onClick={() => requestDelete?.(item)}>
                        {status === 'rejected' ? 'Gửi lại yêu cầu xóa' : 'Yêu cầu xóa vĩnh viễn'}
                      </button>
                    </>}
                    {isAdmin && pending && <>
                      <button type="button" className="ae-button" disabled={busy} onClick={() => rejectDelete?.(item)}>Từ chối</button>
                      <button type="button" className="ae-button ae-button--primary" disabled={busy} onClick={() => approveDelete?.(item)}>Duyệt xóa vĩnh viễn</button>
                    </>}
                    {isAdmin && approved && <button type="button" className="ae-button ae-button--primary" disabled={busy} onClick={() => approveDelete?.(item)}>Hoàn tất xóa vĩnh viễn</button>}
                  </div>
                </td>
              </tr>;
            })}</tbody>
          </table>
        </div>
      )}
    </section>
  );
}
