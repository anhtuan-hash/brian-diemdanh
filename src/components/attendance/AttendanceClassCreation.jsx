import React, { useId, useRef, useState } from 'react';

export async function createAttendanceClass(client, form, members = []) {
  const { data, error } = await client.rpc('bes_create_extra_class_with_members', {
    p_class_type: form.type,
    p_class_name: form.name,
    p_subject: form.subject,
    p_source_key: form.sourceKey ?? null,
    p_school_year: form.year,
    p_grade_level: form.grade,
    p_teacher_names: form.teachers,
    p_members: members,
  });
  if (error) throw error;
  return Array.isArray(data) ? data[0] : data;
}

export default function AttendanceClassCreation({ client, disabled, onCreated }) {
  const dialog = useRef(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const headingId = useId();
  const today = new Date();
  const vietnamMonth = Number(new Intl.DateTimeFormat('en', {
    timeZone: 'Asia/Ho_Chi_Minh', month: 'numeric',
  }).format(today));
  const vietnamYear = Number(new Intl.DateTimeFormat('en', {
    timeZone: 'Asia/Ho_Chi_Minh', year: 'numeric',
  }).format(today));
  const schoolYearStart = vietnamMonth < 8 ? vietnamYear - 1 : vietnamYear;

  async function submit(event) {
    event.preventDefault();
    if (saving) return;
    const fields = new FormData(event.currentTarget);
    const value = (name) => String(fields.get(name) || '').trim();
    const form = {
      type: value('type'),
      name: value('name'),
      subject: value('subject'),
      year: value('year'),
      grade: value('grade'),
      teachers: [...new Set(value('teachers').split(/[\n,;]+/).map((name) => name.trim()).filter(Boolean))],
    };
    if (!form.name || !form.subject || !form.year || !form.teachers.length) {
      setError('Vui lòng nhập tên lớp, môn học, năm học và ít nhất một giáo viên.');
      return;
    }
    setError('');
    setSaving(true);
    try {
      const created = await createAttendanceClass(client, form);
      dialog.current.close();
      onCreated(created);
    } catch (saveError) {
      setError(saveError?.message || 'Chưa tạo được lớp.');
    } finally {
      setSaving(false);
    }
  }

  return <>
    <button type="button" className="ae-button" disabled={disabled} onClick={() => {
      dialog.current.querySelector('form').reset();
      setError('');
      dialog.current.showModal();
    }}>Tạo lớp mới</button>
    <dialog ref={dialog} className="attendance-adjustment-dialog" aria-labelledby={headingId}
      onCancel={(event) => { if (saving) event.preventDefault(); }}>
      <form onSubmit={submit}>
        <h3 id={headingId}>Tạo lớp phụ đạo hoặc bồi dưỡng</h3>
        <fieldset disabled={saving} className="attendance-admin-fields">
          <label>Loại lớp<select name="type" defaultValue="gifted">
            <option value="remedial">Phụ đạo</option>
            <option value="gifted">Bồi dưỡng HSG</option>
          </select></label>
          <label>Khối<select name="grade" defaultValue="" required>
            <option value="" disabled>Chọn khối</option>
            <option value="10">10</option><option value="11">11</option><option value="12">12</option>
          </select></label>
          <label className="attendance-admin-fields__wide">Tên lớp<input name="name" required /></label>
          <label>Môn học<input name="subject" required /></label>
          <label>Năm học<input name="year" defaultValue={schoolYearStart + '-' + (schoolYearStart + 1)} required /></label>
          <label className="attendance-admin-fields__wide">Giáo viên phụ trách
            <textarea name="teachers" rows="2" placeholder="Có thể nhập một giáo viên trên mỗi dòng" required />
          </label>
        </fieldset>
        {error && <p className="attendance-adjustment-error" role="alert">{error}</p>}
        <footer>
          <button type="button" disabled={saving} onClick={() => dialog.current.close()}>Hủy</button>
          <button type="submit" disabled={saving}>{saving ? 'Đang lưu…' : 'Tạo lớp'}</button>
        </footer>
      </form>
    </dialog>
  </>;
}
