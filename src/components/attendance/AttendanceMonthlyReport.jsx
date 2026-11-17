import React, { useEffect, useMemo, useRef, useState } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import AttendanceEditorialHeading from './AttendanceEditorialHeading.jsx';
import { buildAttendanceReport, normalizeSupplementalReportData, uniqueReportTeachers } from '../../utils/attendanceReport.js';
import { downloadAttendanceReportXlsx, printAttendanceReportPdf } from '../../utils/attendanceReportExport.js';
import StudentAttendanceReport from './StudentAttendanceReport.jsx';

const REPORT_SESSION_COLUMNS = 'id,class_id,class_type,class_name,subject,teacher_name,attendance_date,checked_at,checked_by,checked_by_name,total_students,present_count,absent_count,note,session_status,lesson_periods,cancellation_reason,teaching_room,teaching_time_range';
const REPORT_RECORD_COLUMNS = 'id,session_id,class_id,member_id,member_key,student_code,student_full_name,school_class_name,status,recorded_at,absence_reason_code,absence_note';
const REPORT_CHANGE_COLUMNS = 'id,session_id,record_id,class_id,member_key,student_full_name,change_kind,changed_by,changed_by_name,changed_at,old_status,new_status,old_absence_reason_code,new_absence_reason_code,old_absence_note,new_absence_note,session_note_before,session_note_after';
const VIETNAM_TIME_ZONE = 'Asia/Ho_Chi_Minh';

function monthBounds(month) {
  const [year, value] = String(month || '').split('-').map(Number);
  if (!year || !value) return null;
  const start = `${year}-${String(value).padStart(2, '0')}-01`;
  const nextDate = new Date(Date.UTC(year, value, 1));
  const next = `${nextDate.getUTCFullYear()}-${String(nextDate.getUTCMonth() + 1).padStart(2, '0')}-01`;
  return { start, next };
}

function vietnamDateString(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: VIETNAM_TIME_ZONE,
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(date);
  const values = Object.fromEntries(parts.filter((part) => part.type !== 'literal').map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function formatDate(value) {
  const match = String(value || '').match(/^(\d{4})-(\d{2})-(\d{2})/);
  return match ? `${match[3]}/${match[2]}/${match[1]}` : '—';
}

function formatCheckedTime(value) {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '—';
  return new Intl.DateTimeFormat('vi-VN', {
    timeZone: VIETNAM_TIME_ZONE,
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).format(date);
}

function pct(value) {
  return `${(Number(value || 0) * 100).toFixed(1).replace('.', ',')}%`;
}

function periodLabel(value) {
  return `${String(Number(value || 0)).replace('.', ',')} tiết`;
}

function classTypeLabel(value) {
  return value === 'gifted' ? 'Bồi dưỡng HSG' : value === 'remedial' ? 'Phụ đạo' : value === 'supplemental' ? 'Học bổ sung' : '—';
}

function readStored(key, fallback = '') {
  try { return window.localStorage.getItem(key) || fallback; } catch { return fallback; }
}

function remember(key, value) {
  try { window.localStorage.setItem(key, value); } catch { /* optional convenience only */ }
}

function automaticRemarks(report) {
  if (!report.sessionRows.length) return 'Không có dữ liệu phù hợp bộ lọc trong kỳ báo cáo.';
  const attendance = pct(report.metrics.attendanceRate);
  const cancelled = report.metrics.cancelledSessions ? ` Có ${report.metrics.cancelledSessions} buổi đã hủy.` : '';
  return `Trong kỳ báo cáo có ${report.metrics.completedSessions} buổi đã dạy, tổng ${String(report.metrics.totalPeriods).replace('.', ',')} tiết; tỷ lệ chuyên cần đạt ${attendance}.${cancelled}`;
}

export default function AttendanceMonthlyReport({ client, classes = [], month, onMonthChange, onError, includeSupplemental = false, language = 'vi' }) {
  const [mode, setMode] = useState('month');
  const [date, setDate] = useState(vietnamDateString());
  const [sessions, setSessions] = useState([]);
  const [supplementalClasses, setSupplementalClasses] = useState([]);
  const [activityType, setActivityType] = useState('all');
  const [records, setRecords] = useState([]);
  const [changes, setChanges] = useState([]);
  const [classId, setClassId] = useState('all');
  const [teacherName, setTeacherName] = useState('all');
  const [teacherSort, setTeacherSort] = useState('periods-desc');
  const [reporterName, setReporterName] = useState(() => readStored('attendance.reporterName'));
  const [reporterTitle, setReporterTitle] = useState(() => readStored('attendance.reporterTitle'));
  const [generalRemarks, setGeneralRemarks] = useState('');
  const remarksDirty = useRef(false);
  const teacherTrackRef = useRef(null);
  const [loading, setLoading] = useState(false);
  const [reportDimension, setReportDimension] = useState('teacher');

  useEffect(() => {
    function handleActivityFilter(event) {
      if (event?.detail?.tab !== 'report') return;
      const nextType = ['all', 'remedial', 'enrichment', 'supplemental'].includes(event?.detail?.activityType)
        ? event.detail.activityType
        : 'all';
      setActivityType(nextType);
      setClassId('all');
      setTeacherName('all');
      remarksDirty.current = false;
    }
    window.addEventListener('bes-attendance-activity-filter-change', handleActivityFilter);
    return () => window.removeEventListener('bes-attendance-activity-filter-change', handleActivityFilter);
  }, []);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!client) return;
      const bounds = mode === 'month' ? monthBounds(month) : null;
      if (mode === 'month' && !bounds) return;
      if (mode === 'day' && !date) return;
      setLoading(true);
      try {
        let sessionQuery = client.from('bes_extra_attendance_sessions')
          .select(REPORT_SESSION_COLUMNS)
          .order('attendance_date', { ascending: true });
        if (mode === 'day') sessionQuery = sessionQuery.eq('attendance_date', date);
        else sessionQuery = sessionQuery.gte('attendance_date', bounds.start).lt('attendance_date', bounds.next);
        const sessionResult = await sessionQuery;
        if (sessionResult.error) throw sessionResult.error;
        const extraSessions = sessionResult.data || [];
        const sessionIds = extraSessions.map((row) => row.id);
        const completedIds = extraSessions.filter((row) => row.session_status !== 'cancelled').map((row) => row.id);
        let supplementalData = { sessions: [], records: [], classes: [] };
        if (includeSupplemental) {
          const supplementalFrom = mode === 'day' ? date : bounds.start;
          const supplementalTo = mode === 'day' ? date : bounds.next;
          const supplementalResult = await client.rpc('bes_list_supplemental_history', { p_from: supplementalFrom, p_to: supplementalTo, p_query: '' });
          if (supplementalResult.error) throw supplementalResult.error;
          supplementalData = normalizeSupplementalReportData(supplementalResult.data || []);
        }
        let nextRecords = [...supplementalData.records];
        let nextChanges = [];
        if (completedIds.length) {
          const recordResult = await client.from('bes_extra_attendance_records')
            .select(REPORT_RECORD_COLUMNS)
            .in('session_id', completedIds)
            .order('student_full_name', { ascending: true });
          if (recordResult.error) throw recordResult.error;
          nextRecords = [...(recordResult.data || []), ...supplementalData.records];
        }
        if (sessionIds.length) {
          const changeResult = await client.from('bes_extra_attendance_record_changes')
            .select(REPORT_CHANGE_COLUMNS)
            .in('session_id', sessionIds)
            .order('changed_at', { ascending: true });
          if (changeResult.error) throw changeResult.error;
          nextChanges = changeResult.data || [];
        }
        if (!cancelled) {
          setSessions([...extraSessions, ...supplementalData.sessions]);
          setSupplementalClasses(supplementalData.classes);
          setRecords(nextRecords);
          setChanges(nextChanges);
          remarksDirty.current = false;
        }
      } catch (error) {
        if (!cancelled) onError?.(error?.message || 'Không thể tải báo cáo điểm danh.');
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, [client, mode, month, date, includeSupplemental]);

  const reportClasses = useMemo(() => [...classes, ...supplementalClasses], [classes, supplementalClasses]);
  const teachers = useMemo(() => uniqueReportTeachers(sessions, month, { mode, date }), [sessions, month, mode, date]);
  useEffect(() => { if (teacherName !== 'all' && !teachers.includes(teacherName)) setTeacherName('all'); }, [teachers.join('|')]);
  useEffect(() => { if (classId !== 'all' && !reportClasses.some((row) => String(row.id) === String(classId))) setClassId('all'); }, [reportClasses]);

  const report = useMemo(() => buildAttendanceReport({ sessions, records, changes, classes: reportClasses, mode, month, date, activityType, classId, teacherName }), [sessions, records, changes, reportClasses, mode, month, date, activityType, classId, teacherName]);
  useEffect(() => {
    if (!remarksDirty.current) setGeneralRemarks(automaticRemarks(report));
  }, [report.metrics.completedSessions, report.metrics.cancelledSessions, report.metrics.totalPeriods, report.metrics.attendanceRate, report.sessionRows.length, classId, teacherName, mode, month, date]);

  const sortedTeacherRows = useMemo(() => {
    const rows = [...report.teacherRows];
    if (teacherSort === 'attendance-desc') return rows.sort((a, b) => Number(b.attendance_rate || 0) - Number(a.attendance_rate || 0) || Number(b.total_periods || 0) - Number(a.total_periods || 0));
    if (teacherSort === 'name-asc') return rows.sort((a, b) => String(a.teacher_name || '').localeCompare(String(b.teacher_name || ''), 'vi'));
    return rows.sort((a, b) => Number(b.total_periods || 0) - Number(a.total_periods || 0) || String(a.teacher_name || '').localeCompare(String(b.teacher_name || ''), 'vi'));
  }, [report.teacherRows, teacherSort]);

  const selectedClass = reportClasses.find((row) => String(row.id) === String(classId));
  const periodLabelText = mode === 'day' ? formatDate(date) : `Tháng ${String(month || '').slice(5, 7)}/${String(month || '').slice(0, 4)}`;
  const exportFilters = {
    mode,
    month,
    date,
    periodLabel: periodLabelText,
    classLabel: classId === 'all' ? 'Tất cả lớp' : (selectedClass?.class_name || 'Lớp đã chọn'),
    teacherLabel: teacherName === 'all' ? 'Tất cả giáo viên' : teacherName,
    reporterName: reporterName.trim(),
    reporterTitle: reporterTitle.trim(),
    generalRemarks: generalRemarks.trim(),
  };

  function changeMode(nextMode) {
    setMode(nextMode);
    setTeacherName('all');
    remarksDirty.current = false;
  }

  function updateReporterName(value) {
    setReporterName(value);
    remember('attendance.reporterName', value);
  }

  function updateReporterTitle(value) {
    setReporterTitle(value);
    remember('attendance.reporterTitle', value);
  }

  function scrollTeacherTrack(direction) {
    const track = teacherTrackRef.current;
    if (!track) return;
    track.scrollBy({ left: direction * Math.max(280, track.clientWidth * 0.82), behavior: 'smooth' });
  }

  const isTeacherReport = reportDimension === 'teacher';
  const metrics = [
    { label: 'Buổi đã dạy', value: report.metrics.completedSessions },
    { label: 'Lượt có mặt', value: report.metrics.presentInstances },
    { label: 'Tổng số tiết', value: Number(report.metrics.totalPeriods).toLocaleString('vi-VN') },
    { label: 'Buổi đã hủy', value: report.metrics.cancelledSessions },
  ].map((metric) => loading ? { ...metric, value: null } : metric);
  const visibleClasses = reportClasses.filter((row) => row.active !== false && (
    activityType === 'all' || row.class_type === (activityType === 'enrichment' ? 'gifted' : activityType)
  ));

  function changeActivityType(value) {
    setActivityType(value);
    setClassId('all');
    setTeacherName('all');
    remarksDirty.current = false;
  }

  return (
    <section className="ae-report" aria-label="Báo cáo điểm danh">
      <AttendanceEditorialHeading title="Báo cáo" className="ae-heading--report" metrics={isTeacherReport ? metrics : []} />
      <div className="ae-report__filters ae-field-row">
        <div className="ae-segments" role="group" aria-label="Đối tượng báo cáo">
          <button type="button" aria-pressed={isTeacherReport} onClick={() => setReportDimension('teacher')}>Theo giáo viên</button>
          <button type="button" aria-pressed={!isTeacherReport} onClick={() => setReportDimension('student')}>Theo học sinh</button>
        </div>
        <label><span>Loại hoạt động</span>
          <select value={activityType} onChange={(event) => changeActivityType(event.target.value)}>
            <option value="all">Tất cả</option><option value="remedial">Phụ đạo</option><option value="enrichment">Bồi dưỡng</option>
            {includeSupplemental && <option value="supplemental">Học bổ sung</option>}
          </select>
        </label>
        {isTeacherReport && <>
          {mode === 'month'
            ? <label><span>Tháng</span><input type="month" value={month} onChange={(event) => {
              onMonthChange?.(event.target.value);
              remarksDirty.current = false;
            }} /></label>
            : <label><span>Ngày</span><input type="date" value={date} max={vietnamDateString()} onChange={(event) => {
              setDate(event.target.value);
              remarksDirty.current = false;
            }} /></label>}
          <label><span>Lớp</span>
            <select value={classId} onChange={(event) => { setClassId(event.target.value); remarksDirty.current = false; }}>
              <option value="all">Tất cả lớp</option>
              {visibleClasses.map((row) => <option key={row.id} value={row.id}>{row.class_name}</option>)}
            </select>
          </label>
          <label><span>Giáo viên</span>
            <select value={teacherName} onChange={(event) => { setTeacherName(event.target.value); remarksDirty.current = false; }}>
              <option value="all">Tất cả giáo viên</option>
              {teachers.map((name) => <option key={name} value={name}>{name}</option>)}
            </select>
          </label>
          <div className="ae-segments" role="group" aria-label="Chế độ báo cáo">
            <button type="button" aria-pressed={mode === 'month'} onClick={() => changeMode('month')}>Theo tháng</button>
            <button type="button" aria-pressed={mode === 'day'} onClick={() => changeMode('day')}>Theo ngày</button>
          </div>
        </>}
      </div>

      {!isTeacherReport ? (
        <StudentAttendanceReport client={client} language={language} month={month}
          includeSupplemental={includeSupplemental} activityType={activityType} reporterName={reporterName}
          reporterTitle={reporterTitle} onReporterNameChange={updateReporterName}
          onReporterTitleChange={updateReporterTitle} onError={onError} />
      ) : <>
        <div className="ae-report__meta ae-field-row" aria-label="Thông tin người báo cáo">
          <label><span>Người báo cáo</span><input value={reporterName}
            onChange={(event) => updateReporterName(event.target.value)} placeholder="Nhập họ và tên" /></label>
          <label><span>Chức vụ</span><input value={reporterTitle}
            onChange={(event) => updateReporterTitle(event.target.value)} placeholder="Ví dụ: Phó hiệu trưởng" /></label>
          <label><span>Nhận xét chung</span><textarea value={generalRemarks} rows={2}
            onChange={(event) => { remarksDirty.current = true; setGeneralRemarks(event.target.value); }} /></label>
        </div>

        {loading ? <p role="status" className="ae-message">Đang tổng hợp dữ liệu {mode === 'day' ? 'ngày' : 'tháng'}…</p> : <>
          <section className="ae-report__teachers" aria-labelledby="ae-report-teachers-title">
            <div className="ae-report__teacher-tools">
              <h2 id="ae-report-teachers-title">Tổng hợp theo giáo viên</h2>
              <div className="ae-report__teacher-controls">
                <select aria-label="Sắp xếp giáo viên" value={teacherSort} onChange={(event) => setTeacherSort(event.target.value)}>
                  <option value="periods-desc">Số tiết (giảm dần)</option><option value="attendance-desc">Chuyên cần (cao nhất)</option>
                  <option value="name-asc">Tên giáo viên (A–Z)</option>
                </select>
                <button type="button" className="ae-button" aria-label="Giáo viên trước" onClick={() => scrollTeacherTrack(-1)}><ChevronLeft size={16} aria-hidden="true" /></button>
                <button type="button" className="ae-button" aria-label="Giáo viên tiếp theo" onClick={() => scrollTeacherTrack(1)}><ChevronRight size={16} aria-hidden="true" /></button>
              </div>
            </div>
            <div className="ae-report__teacher-track" ref={teacherTrackRef} tabIndex={0} role="region" aria-label="Danh sách giáo viên trong kỳ báo cáo">
              {sortedTeacherRows.map((row, index) => (
                <details className="ae-report__teacher" key={row.teacher_name}>
                  <summary>
                    <span className="ae-report__teacher-rank">{String(index + 1).padStart(2, '0')}</span>
                    <span><strong>{row.teacher_name}</strong><b>{periodLabel(row.total_periods)}</b></span>
                  </summary>
                  <small>{row.completed_sessions} buổi · {row.distinct_classes} lớp · {pct(row.attendance_rate)} chuyên cần</small>
                  <small>{row.present_instances} có mặt · {row.late_instances} đi trễ · {row.absent_instances} vắng</small>
                </details>
              ))}
              {sortedTeacherRows.length === 0 && <p className="ae-message">Chưa có buổi dạy phù hợp bộ lọc.</p>}
            </div>
          </section>

          <section aria-labelledby="ae-report-sessions-title">
            <div className="ae-section-heading">
              <h2 id="ae-report-sessions-title">Chi tiết buổi học</h2>
              <div className="ae-actions">
                <button type="button" className="ae-button" onClick={() => downloadAttendanceReportXlsx(report, exportFilters)}>Xuất Excel</button>
                <button type="button" className="ae-button ae-button--primary" onClick={async () => {
                  try { await printAttendanceReportPdf(report, exportFilters); } catch (error) { onError?.(error.message); }
                }}>Xuất PDF báo cáo</button>
              </div>
            </div>
            <div className="ae-table-scroll" tabIndex={0} role="region" aria-labelledby="ae-report-sessions-title">
              <table className="ae-table ae-report__table">
                <thead><tr>{['Ngày', 'Giờ dạy', 'Giờ chốt', 'Lớp / Loại', 'Môn', 'Phòng học', 'Giáo viên dạy',
                  'Người điểm danh', 'Điều chỉnh gần nhất', 'Số tiết', 'Sĩ số', 'Có mặt', 'Đi trễ', 'Vắng', 'Tỷ lệ',
                  'Trạng thái / ghi chú'].map((label) => <th key={label} scope="col">{label}</th>)}</tr></thead>
                <tbody>{report.sessionRows.map((row) => (
                  <tr key={row.id}>
                    <td>{formatDate(row.attendance_date)}</td><td>{row.teaching_time_range || 'Chưa ghi'}</td>
                    <td>{formatCheckedTime(row.checked_at)}</td>
                    <td><strong>{row.class_name}</strong><small>{classTypeLabel(row.class_type)}</small></td>
                    <td>{row.subject || '—'}</td><td>{row.teaching_room || 'Chưa ghi'}</td><td>{row.teacher_name || '—'}</td>
                    <td><strong>{row.checked_by_name || '—'}</strong></td>
                    <td>
                      <span className={`ae-tag ${row.change_count ? 'is-gifted' : 'is-amber'}`}>{row.change_count ? 'Đã điều chỉnh' : 'Chưa điều chỉnh'}</span>
                      {row.change_count > 0 && <small>{[row.latest_changed_by_name, row.latest_changed_at && formatCheckedTime(row.latest_changed_at), `${row.change_count} lần`].filter(Boolean).join(' · ')}</small>}
                    </td>
                    <td>{row.session_status === 'cancelled' ? '0' : String(row.lesson_periods).replace('.', ',')}</td>
                    <td>{row.total_students ?? '—'}</td><td>{row.present_count ?? '—'}</td><td>{row.late_count ?? '—'}</td>
                    <td>{row.absent_count ?? '—'}</td><td>{row.attendance_rate === null ? '—' : pct(row.attendance_rate)}</td>
                    <td><strong>{row.session_status === 'cancelled' ? 'Đã hủy' : 'Đã điểm danh'}</strong>{row.note && <small>{row.note}</small>}</td>
                  </tr>
                ))}
                {report.sessionRows.length === 0 && <tr><td colSpan={16}>Không có dữ liệu phù hợp bộ lọc.</td></tr>}</tbody>
              </table>
            </div>
          </section>

          <section aria-labelledby="ae-report-absences-title">
            <div className="ae-section-heading"><h2 id="ae-report-absences-title">Chi tiết học sinh vắng</h2></div>
            <div className="ae-table-scroll" tabIndex={0} role="region" aria-labelledby="ae-report-absences-title">
              <table className="ae-table ae-report__table ae-report__table--absences">
                <thead><tr>{['Ngày', 'Học sinh', 'Lớp chính khóa', 'Lý do vắng', 'Ghi chú', 'Lớp phụ đạo/bồi dưỡng',
                  'Môn', 'Giáo viên', 'Giờ dạy', 'Giờ chốt', 'Phòng học'].map((label) => <th key={label} scope="col">{label}</th>)}</tr></thead>
                <tbody>{report.absenceRows.map((row, index) => (
                  <tr key={`${row.session_id}-${row.student_code || row.student_full_name}-${index}`}>
                    <td>{formatDate(row.attendance_date)}</td>
                    <td><strong>{row.student_full_name}</strong>{row.student_code && <small>{row.student_code}</small>}</td>
                    <td>{row.school_class_name || '—'}</td><td>{row.reason_label}</td><td>{row.absence_note || '—'}</td>
                    <td>{row.class_name}</td><td>{row.subject || '—'}</td><td>{row.teacher_name || '—'}</td>
                    <td>{row.teaching_time_range || 'Chưa ghi'}</td><td>{formatCheckedTime(row.checked_at)}</td>
                    <td>{row.teaching_room || 'Chưa ghi'}</td>
                  </tr>
                ))}
                {report.absenceRows.length === 0 && <tr><td colSpan={11}>Không có học sinh vắng trong dữ liệu phù hợp bộ lọc.</td></tr>}</tbody>
              </table>
            </div>
          </section>
        </>}
      </>}
    </section>
  );
}
