import React, { useEffect, useMemo, useRef, useState } from 'react';
import AttendanceEditorialHeading from './AttendanceEditorialHeading.jsx';
import { normalizeSupplementalReportData } from '../../utils/attendanceReport.js';
import { buildStudentAttendanceReport } from '../../utils/studentAttendanceReport.js';
import { downloadStudentAttendanceExcel, printStudentAttendancePdf } from '../../utils/studentAttendanceExport.js';
import StudentAttendanceProfile from './StudentAttendanceProfile.jsx';
import './StudentAttendanceReport.css';
import './StudentAttendanceReportTheme.css';

const SESSION_FIELDS = 'id,class_id,class_type,class_name,subject,teacher_name,attendance_date,session_status,lesson_periods,teaching_room,teaching_time_range';
const RECORD_FIELDS = 'id,session_id,class_id,member_id,member_key,student_code,student_full_name,school_class_name,status,recorded_at,absence_reason_code,absence_note';
const categoryText = { good: 'Tốt', watch: 'Cần theo dõi', danger: 'Cần quan tâm', unknown: 'Chưa có dữ liệu' };
const rate = (value) => value === null ? '—' : (value * 100).toFixed(1).replace('.', ',') + '%';
const localDay = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Ho_Chi_Minh', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
const monthStart = (month) => /^\d{4}-\d{2}$/.test(String(month || '')) ? month + '-01' : localDay().slice(0, 7) + '-01';
const monthEnd = (month) => /^\d{4}-\d{2}$/.test(String(month || '')) ? new Date(Date.UTC(Number(month.slice(0,4)), Number(month.slice(5,7)), 0)).toISOString().slice(0,10) : localDay();
const split = (items, chunk = 75) => Array.from({length: Math.ceil(items.length / chunk)}, (_,i) => items.slice(i*chunk, (i+1)*chunk));

// PostgREST limits default responses to 1,000 rows. Paginate every query, including
// each group of attendance records, so a large school does not silently lose pupils.
async function allPages(queryFactory, pageSize = 700) {
  const rows = [];
  for (let offset = 0; offset < 150000; offset += pageSize) {
    const { data, error } = await queryFactory().range(offset, offset + pageSize - 1);
    if (error) throw error;
    const part = Array.isArray(data) ? data : [];
    rows.push(...part);
    if (part.length < pageSize) return rows;
  }
  throw new Error('Báo cáo quá lớn để tải toàn bộ an toàn. Hãy thu hẹp khoảng ngày.');
}

async function readHistory(client, from, to, includeSupplemental, activity) {
  const needExtra = activity !== 'supplemental';
  const needSupplemental = includeSupplemental && !['remedial', 'enrichment'].includes(activity);
  let sessions = [], records = [];
  if (needExtra) {
    sessions = await allPages(() => client.from('bes_extra_attendance_sessions')
      .select(SESSION_FIELDS).gte('attendance_date', from).lte('attendance_date', to)
      .order('attendance_date', {ascending:true}).order('id', {ascending:true}));
    const ids = sessions.filter(s=>s.session_status==='completed').map(s=>s.id);
    for (const idGroup of split(ids)) {
      const batch = await allPages(() => client.from('bes_extra_attendance_records')
        .select(RECORD_FIELDS).in('session_id',idGroup)
        .order('id', {ascending:true}));
      records.push(...batch);
    }
  }
  if (needSupplemental) {
    const {data, error} = await client.rpc('bes_list_supplemental_history', {p_from:from,p_to:to,p_query:''});
    if (error) throw error;
    // The existing normalizer marks every non-cancelled item completed.
    // Feed it only actually confirmed sessions to avoid false absences.
    const confirmed = (Array.isArray(data)?data:[]).filter(row=>row.status==='confirmed' || row.status==='completed');
    const normalized = normalizeSupplementalReportData(confirmed);
    sessions = sessions.concat(normalized.sessions);
    records = records.concat(normalized.records);
  }
  return {sessions,records};
}

const numberFormat = new Intl.NumberFormat('vi-VN');

export default function StudentAttendanceReport({client, month, onError, includeSupplemental=true, activityType='all', reporterName='', reporterTitle='', onReporterNameChange, onReporterTitleChange, language='vi', reportControls}) {
  const [from,setFrom] = useState(()=>monthStart(month));
  const [to,setTo] = useState(()=>monthEnd(month));
  const category = activityType;
  const [classId,setClassId] = useState('all');
  const [schoolClass,setSchoolClass] = useState('all');
  const [grade,setGrade] = useState('all');
  const [subject,setSubject] = useState('all');
  const [teacher,setTeacher] = useState('all');
  const [search,setSearch] = useState('');
  const [warning,setWarning] = useState('all');
  const [sorting,setSorting] = useState('rate-asc');
  const [thresholds,setThresholds] = useState({goodAt:90,warningAt:80,unexcusedAt:2,lateAt:3});
  const [dataset,setDataset] = useState({sessions:[],records:[]});
  const [loading,setLoading] = useState(false);
  const [error,setError] = useState('');
  const [refreshKey,setRefreshKey] = useState(0);
  const [selectedStudent,setSelectedStudent] = useState('');
  const [profileIdentity,setProfileIdentity] = useState(null);
  const reportScrollY = useRef(0);
  const rosterScrollTop = useRef(0);
  const rosterRef = useRef(null);
  const [checked,setChecked] = useState([]);
  // A refreshed browser tab has no in-memory student identity. Discard only
  // the stale profile URL marker; never infer a pupil from a public URL.
  useEffect(() => {
    if (typeof window === 'undefined' || !window.location.hash.startsWith('#/attendance')) return;
    const params=new URLSearchParams(window.location.hash.split('?')[1] || '');
    if (params.get('profile') !== '1') return;
    params.delete('profile');
    window.history.replaceState(null,'','#/attendance?'+params.toString());
  }, []);
  useEffect(() => { setClassId('all'); }, [category]);
  useEffect(()=>{setFrom(monthStart(month));setTo(monthEnd(month));},[month]);
  useEffect(()=>{
    if (!client || !from || !to || from > to) return;
    let stopped = false;
    setLoading(true);setError('');
    readHistory(client,from,to,includeSupplemental,category).then(data=>{
      if(stopped)return;
      setDataset(data);
    }).catch(err=>{if(stopped)return;setError(err.message||'Không tải được dữ liệu.');onError?.(err.message||'Không tải được dữ liệu.');})
      .finally(()=>{if(!stopped)setLoading(false);});
    return ()=>{stopped=true;};
  },[client,from,to,category,includeSupplemental,refreshKey]);

  const allClasses = useMemo(() => [...new Map(dataset.sessions.map(s=>[String(s.class_id),s])).values()]
    .sort((a,b)=>String(a.class_name).localeCompare(String(b.class_name),'vi')), [dataset.sessions]);
  const classes = useMemo(() => [...new Set(dataset.records.map(r=>String(r.school_class_name||'').trim()).filter(Boolean))].sort((a,b)=>a.localeCompare(b,'vi')), [dataset.records]);
  const subjects = useMemo(() => [...new Set(dataset.sessions.map(s=>s.subject).filter(Boolean))].sort((a,b)=>a.localeCompare(b,'vi')), [dataset.sessions]);
  const teachers = useMemo(() => [...new Set(dataset.sessions.map(s=>s.teacher_name).filter(Boolean))].sort((a,b)=>a.localeCompare(b,'vi')), [dataset.sessions]);
  const result = useMemo(()=>buildStudentAttendanceReport({
    ...dataset,activityType:category,classId,schoolClass,grade,subject,teacher,search,alert:warning,thresholds,
  }),[dataset,category,classId,schoolClass,grade,subject,teacher,search,warning,thresholds]);
  const students = useMemo(()=>{
    const values = [...result.students];
    if(sorting==='name')return values.sort((a,b)=>a.name.localeCompare(b.name,'vi'));
    if(sorting==='rate-desc')return values.sort((a,b)=>(b.rate??-1)-(a.rate??-1));
    if(sorting==='absent-desc')return values.sort((a,b)=>b.absentPeriods-a.absentPeriods);
    return values;
  },[result.students,sorting]);
  useEffect(()=>{setChecked([]);},[category,classId,schoolClass,grade,subject,teacher,search,warning,from,to,refreshKey]);
  const emptyProfile = profileIdentity ? {
    ...profileIdentity, sessionCount:0, totalPeriods:0, presentPeriods:0, absentPeriods:0,
    excusedCount:0, unexcusedCount:0, lateCount:0, rate:null, alert:'unknown',
    monthRows:[], subjectRows:[], details:[],
  } : null;
  const selected = selectedStudent
    ? (loading ? emptyProfile : (students.find(s=>s.key===selectedStudent) || emptyProfile))
    : null;
  useEffect(() => {
    if (!selectedStudent) return undefined;
    const closeOnHistory = () => {
      const params=new URLSearchParams(window.location.hash.split('?')[1] || '');
      if (params.get('profile') !== '1') {
        setSelectedStudent('');
        setProfileIdentity(null);
        window.requestAnimationFrame(() => window.scrollTo({top:reportScrollY.current,behavior:'instant'}));
      }
    };
    window.addEventListener('popstate',closeOnHistory);
    window.addEventListener('hashchange',closeOnHistory);
    return () => {
      window.removeEventListener('popstate',closeOnHistory);
      window.removeEventListener('hashchange',closeOnHistory);
    };
  }, [selectedStudent]);
  useEffect(() => {
    if (selectedStudent || loading || !rosterRef.current) return;
    rosterRef.current.scrollTop = rosterScrollTop.current;
  }, [selectedStudent, loading]);

  useEffect(() => {
    if (selectedStudent) return;
    rosterScrollTop.current = 0;
    if (rosterRef.current) rosterRef.current.scrollTop = 0;
  }, [category, classId, schoolClass, grade, subject, teacher, search, warning, sorting, thresholds, from, to, refreshKey]);

  function openProfile(student) {
    reportScrollY.current=window.scrollY || 0;
    rosterScrollTop.current = rosterRef.current?.scrollTop || 0;
    setProfileIdentity({
      key:student.key,name:student.name,studentCode:student.studentCode,
      schoolClass:student.schoolClass,
    });
    setSelectedStudent(student.key);
    if (window.location.hash.startsWith('#/attendance')) {
      const params=new URLSearchParams(window.location.hash.split('?')[1] || '');
      params.set('tab','report');
      params.set('profile','1');
      window.history.pushState({...window.history.state, attendanceStudentProfile:true},'', '#/attendance?'+params.toString());
    }
    window.requestAnimationFrame(() => window.scrollTo({top:0,behavior:'instant'}));
  }
  function closeProfile() {
    setSelectedStudent('');
    setProfileIdentity(null);
    if (window.location.hash.startsWith('#/attendance')) {
      const params=new URLSearchParams(window.location.hash.split('?')[1] || '');
      if (params.get('profile') === '1') {
        params.delete('profile');
        window.history.replaceState(window.history.state,'','#/attendance?'+params.toString());
      }
    }
    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => window.scrollTo({top:reportScrollY.current,behavior:'instant'}));
    });
  }
  function changeProfileMonth(value) {
    if (!/^\d{4}-\d{2}$/.test(value)) return;
    setFrom(monthStart(value));
    setTo(monthEnd(value));
  }
  const exportStudents = checked.length ? students.filter(s=>checked.includes(s.key)) : students;
  const params = {from,to,activityType:category,reporterName,reporterTitle};
  const chooseAll = (checkedValue)=>setChecked(checkedValue?students.map(s=>s.key):[]);
  const doExcel = ()=>{try{downloadStudentAttendanceExcel(exportStudents,params);}catch(e){onError?.(e.message);}};
  const doPdf = async ()=>{try{await printStudentAttendancePdf(exportStudents,params);}catch(e){onError?.(e.message);}};
  const options = (data,selector)=>data.map(s=><option key={selector(s)} value={selector(s)}>{selector(s)}</option>);
  const individualExcel = () => {
    if (!selected || loading) return;
    try { downloadStudentAttendanceExcel([selected],params); }
    catch (error) { onError?.(error?.message || 'Không xuất được Excel cá nhân.'); }
  };
  const individualPdf = async () => {
    if (!selected || loading) return;
    try { await printStudentAttendancePdf([selected],params); }
    catch (error) { onError?.(error?.message || 'Không xuất được PDF cá nhân.'); }
  };

  const canShowData = !loading && !error && from && to && from <= to;
  const metrics = [
    { label: 'Học sinh', value: numberFormat.format(result.totals.students) },
    { label: 'Lượt tiết', value: numberFormat.format(result.totals.totalPeriods) },
    { label: 'Chuyên cần', value: rate(result.totals.rate) },
    { label: 'Cần theo dõi', value: numberFormat.format(result.totals.atRisk) },
  ].map((metric) => canShowData ? metric : { ...metric, value: null });
  const hasExport = Boolean(canShowData && exportStudents.length);

  return (
    <section className="ae-report ae-student-report" aria-label="Báo cáo theo học sinh">
      <AttendanceEditorialHeading title="Báo cáo" className="ae-heading--report" metrics={selected ? [] : metrics} />
      <div className="ae-field-row ae-student-report__toolbar">
        {reportControls}
        {!selected && <div className="ae-actions">
          <button type="button" className="ae-button" disabled={!hasExport} onClick={doExcel}>Xuất Excel</button>
          <button type="button" className="ae-button ae-button--primary" disabled={!hasExport} onClick={doPdf}>In / Lưu PDF</button>
        </div>}
      </div>

      {selected ? <StudentAttendanceProfile language={language} student={selected} from={from} to={to} loading={loading}
        onBack={closeProfile} onMonthChange={changeProfileMonth} onExcel={individualExcel} onPdf={individualPdf} /> : <>
        <div className="ae-field-row ae-student-report__filters" aria-label="Bộ lọc học sinh">
          <label><span>Từ ngày</span><input type="date" lang="vi" value={from} onChange={e=>setFrom(e.target.value)} /></label>
          <label><span>Đến ngày</span><input type="date" lang="vi" value={to} min={from} onChange={e=>setTo(e.target.value)} /></label>
          <label><span>Lớp học</span><select value={classId} onChange={e=>setClassId(e.target.value)}><option value="all">Tất cả lớp</option>{allClasses.filter(s=>category==='all'||s.class_type===(category==='enrichment'?'gifted':category)).map(s=><option key={s.class_id} value={s.class_id}>{s.class_name}</option>)}</select></label>
          <label><span>Khối</span><select value={grade} onChange={e=>setGrade(e.target.value)}><option value="all">Tất cả khối</option><option value="10">Khối 10</option><option value="11">Khối 11</option><option value="12">Khối 12</option></select></label>
          <label><span>Lớp hành chính</span><select value={schoolClass} onChange={e=>setSchoolClass(e.target.value)}><option value="all">Tất cả</option>{options(classes,x=>x)}</select></label>
          <label><span>Môn học</span><select value={subject} onChange={e=>setSubject(e.target.value)}><option value="all">Tất cả môn</option>{options(subjects,x=>x)}</select></label>
          <label><span>Giáo viên</span><select value={teacher} onChange={e=>setTeacher(e.target.value)}><option value="all">Tất cả giáo viên</option>{options(teachers,x=>x)}</select></label>
          <label><span>Tìm học sinh</span><input type="search" placeholder="Tên hoặc mã học sinh" value={search} onChange={e=>setSearch(e.target.value)} /></label>
        </div>

        <div className="ae-field-row ae-student-report__settings">
          <label><span>Người báo cáo</span><input value={reporterName} onChange={e=>onReporterNameChange?.(e.target.value)} placeholder="Nhập họ và tên" /></label>
          <label><span>Chức vụ</span><input value={reporterTitle} onChange={e=>onReporterTitleChange?.(e.target.value)} placeholder="Ví dụ: Phó hiệu trưởng" /></label>
          <label><span>Cảnh báo</span><select value={warning} onChange={e=>setWarning(e.target.value)}><option value="all">Tất cả</option><option value="danger">Cần quan tâm</option><option value="watch">Cần theo dõi</option><option value="good">Tốt</option></select></label>
          <label><span>Sắp xếp</span><select value={sorting} onChange={e=>setSorting(e.target.value)}><option value="rate-asc">Chuyên cần tăng dần</option><option value="rate-desc">Chuyên cần giảm dần</option><option value="absent-desc">Vắng nhiều trước</option><option value="name">Tên A–Z</option></select></label>
          <button type="button" className="ae-button ae-button--primary" disabled={loading || !from || !to || from > to} onClick={()=>setRefreshKey(v=>v+1)}>Cập nhật</button>
          <details className="ae-student-report__thresholds">
            <summary>Thiết lập ngưỡng cảnh báo</summary>
            <div className="ae-field-row">
              <label><span>Tốt từ (%)</span><input type="number" min="1" max="100" value={thresholds.goodAt} onChange={e=>setThresholds(t=>({...t,goodAt:Number(e.target.value)}))} /></label>
              <label><span>Quan tâm dưới (%)</span><input type="number" min="0" max="99" value={thresholds.warningAt} onChange={e=>setThresholds(t=>({...t,warningAt:Number(e.target.value)}))} /></label>
              <label><span>Vắng không phép (buổi)</span><input type="number" min="1" max="100" value={thresholds.unexcusedAt} onChange={e=>setThresholds(t=>({...t,unexcusedAt:Number(e.target.value)}))} /></label>
              <label><span>Đi trễ (buổi)</span><input type="number" min="1" max="100" value={thresholds.lateAt} onChange={e=>setThresholds(t=>({...t,lateAt:Number(e.target.value)}))} /></label>
            </div>
          </details>
        </div>

        {from > to && <p role="alert">Ngày kết thúc phải bằng hoặc sau ngày bắt đầu.</p>}
        {error && <p role="alert">{error} · Dữ liệu chưa được xác nhận là đầy đủ.</p>}
        {loading && <p className="ae-message" role="status">Đang đọc dữ liệu và đối chiếu lịch sử điểm danh…</p>}
        {canShowData && <section aria-labelledby="ae-students-heading">
          <div className="ae-section-heading">
            <h2 id="ae-students-heading">Chuyên cần theo học sinh</h2>
            <strong aria-live="polite">{numberFormat.format(students.length)} học sinh{checked.length ? ` · ${checked.length} đã chọn` : ''}</strong>
          </div>
          <div className="ae-table-scroll ae-student-report__scroll" ref={rosterRef} tabIndex={0} role="region" aria-label="Bảng chuyên cần theo học sinh">
            <table className="ae-table ae-student-report__table">
              <thead><tr>
                <th scope="col"><input type="checkbox" checked={Boolean(students.length)&&students.every(s=>checked.includes(s.key))} onChange={e=>chooseAll(e.target.checked)} aria-label="Chọn tất cả học sinh" /></th>
                {['Học sinh','Lớp','Số lớp','Buổi','Tổng tiết','Có mặt','Vắng','Đi trễ','Chuyên cần','Đánh giá','Chi tiết'].map(label=><th key={label} scope="col">{label}</th>)}
              </tr></thead>
              <tbody>
                {students.map(s => <tr key={s.key} data-alert={s.alert}>
                  <td><input type="checkbox" checked={checked.includes(s.key)} onChange={e=>setChecked(keys=>e.target.checked?[...new Set([...keys,s.key])]:keys.filter(x=>x!==s.key))} aria-label={'Chọn '+s.name} /></td>
                  <th scope="row"><strong>{s.name}</strong>{s.studentCode && <small>{s.studentCode}</small>}</th>
                  <td>{s.schoolClass || '—'}</td><td>{s.classCount}</td><td>{s.sessionCount}</td><td>{s.totalPeriods}</td>
                  <td>{s.presentPeriods}</td><td>{s.absentPeriods}</td><td>{s.lateCount}</td>
                  <td><div className="ae-student-report__rate"><strong>{rate(s.rate)}</strong><span aria-hidden="true"><i style={{ width: ((s.rate || 0) * 100) + '%' }} /></span></div></td>
                  <td><span className="ae-tag ae-student-report__alert">{categoryText[s.alert]}</span></td>
                  <td><button type="button" className="ae-button" onClick={()=>openProfile(s)} aria-label={'Xem hồ sơ chuyên cần của '+s.name}>Xem</button></td>
                </tr>)}
                {!students.length && <tr><td colSpan={12}>Chưa có học sinh có dữ liệu điểm danh đã chốt phù hợp bộ lọc.</td></tr>}
              </tbody>
            </table>
          </div>
          <details className="ae-student-report__notes">
            <summary>Cách tính chuyên cần và phạm vi xuất</summary>
            <p>Chỉ tính bản ghi điểm danh hợp lệ của buổi đã chốt. Đi trễ vẫn tính là có mặt. Số liệu phản ánh mức độ tham gia học. Học sinh chưa có mã được đối chiếu bằng họ tên và lớp hành chính. Khi chọn học sinh, các nút xuất chỉ lấy những hồ sơ đã chọn trong danh sách lọc.</p>
          </details>
        </section>}
      </>}
    </section>
  );
}
