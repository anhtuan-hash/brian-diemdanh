import React, { useEffect, useState } from 'react';
import { getRuntimeClient } from '../services/runtime/core.js';
import { ATTENDANCE_PERMISSION_ITEMS, ATTENDANCE_ACTION_PERMISSION_ITEMS } from '../utils/permissions.js';
import AttendanceEditorialHeading from '../components/attendance/AttendanceEditorialHeading.jsx';
import AttendanceQuickAccount from '../components/attendance/AttendanceQuickAccount.jsx';
import './AttendanceAccountEditorial.css';

const sections = [...ATTENDANCE_PERMISSION_ITEMS, ...ATTENDANCE_ACTION_PERMISSION_ITEMS];

export default function AttendancePermissions() {
  const [accounts, setAccounts] = useState([]);
  const [selectedId, setSelectedId] = useState('');
  const [draft, setDraft] = useState([]);
  const [query, setQuery] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [revision, setRevision] = useState(0);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [creating, setCreating] = useState(false);
  const client = getRuntimeClient();
  const selected = accounts.find((account) => account.id === selectedId);
  const filteredAccounts = accounts.filter((account) =>
    [account.full_name, account.email].some((value) => value?.toLocaleLowerCase('vi').includes(query.trim().toLocaleLowerCase('vi'))));
  const dirty = selected && sections.some(({ id }) => draft.includes(id) !== selected.effective_permissions.includes(id));

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError('');
    async function loadAccounts() {
      try {
        const { data, error: loadError } = await client.rpc('bes_list_attendance_permission_accounts');
        if (loadError) throw loadError;
        if (cancelled) return;
        const rows = data || [];
        setAccounts(rows);
        setSelectedId(rows[0]?.id || '');
        setDraft(rows[0]?.effective_permissions || []);
      } catch (loadError) {
        if (!cancelled) setError(loadError?.message || 'Chưa tải được danh sách tài khoản.');
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    void loadAccounts();
    return () => { cancelled = true; };
  }, [client, revision]);

  function selectAccount(account) {
    setSelectedId(account.id);
    setDraft(account.effective_permissions);
    setError('');
    setNotice('');
  }

  async function save(event) {
    event.preventDefault();
    if (!selected || !dirty || saving) return;
    setSaving(true);
    setError('');
    setNotice('');
    try {
      const { data, error: saveError } = await client.rpc('bes_set_attendance_permissions', {
        p_account: selected.id,
        p_permissions: sections.filter(({ id }) => draft.includes(id)).map(({ id }) => id),
        p_expected: selected.attendance_permissions,
      });
      if (saveError) throw saveError;
      setAccounts((current) => current.map((account) => account.id === selected.id
        ? { ...account, attendance_permissions: data, effective_permissions: data }
        : account));
      setDraft(data);
      setNotice('Đã lưu quyền Điểm danh.');
    } catch (saveError) {
      setError(saveError?.message || 'Chưa lưu được quyền. Vui lòng thử lại.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="attendance-permissions" aria-labelledby="attendance-permissions-title">
      <AttendanceEditorialHeading title="Phân quyền" titleId="attendance-permissions-title"
        metrics={[{ label: 'Tài khoản', value: error && !accounts.length ? '—' : accounts.length }]} loading={loading} />
      {creating ? (
        <AttendanceQuickAccount client={client} sections={sections} onClose={() => setCreating(false)}
          onCreated={(account) => {
            setAccounts((current) => [...current.filter(({ id }) => id !== account.id), account]
              .sort((a, b) => Number(b.approved) - Number(a.approved)
                || (a.full_name || a.email).localeCompare(b.full_name || b.email, 'vi')));
            setQuery('');
          }} />
      ) : (
        <div className="attendance-quick-account__toolbar">
          <button type="button" className="attendance-account__action" disabled={loading || saving || !client}
            onClick={() => setCreating(true)}>Tạo tài khoản nhanh</button>
        </div>
      )}
      {error && <p role="alert" className="attendance-permissions__error">{error} <button type="button" onClick={() => setRevision(revision + 1)}>Tải lại danh sách</button></p>}
      {loading ? <p role="status">Đang tải tài khoản…</p> : (
        <div className="attendance-permissions__layout">
          <aside aria-label="Tài khoản">
            <div className="attendance-permissions__list-heading">
              <label htmlFor="attendance-account-search">Tìm tài khoản</label>
              {query.trim() && <span>{filteredAccounts.length} kết quả</span>}
            </div>
            <input id="attendance-account-search" type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Tên hoặc email" />
            <ul>
              {filteredAccounts.map((account) => <li key={account.id}>
                <button type="button" aria-pressed={selectedId === account.id} disabled={saving} onClick={() => selectAccount(account)}>
                  <strong>{account.full_name || account.email}</strong>
                  {account.full_name && account.email && account.email !== account.full_name && <span>{account.email}</span>}
                  {!account.approved && <small>Chờ duyệt</small>}
                </button>
              </li>)}
            </ul>
            {!filteredAccounts.length && <p>Không tìm thấy tài khoản.</p>}
          </aside>
          {selected && <form onSubmit={save}>
            <fieldset disabled={saving}>
              <legend>
                <strong>{selected.full_name || selected.email}</strong>
                {selected.full_name && selected.email && <span>{selected.email}</span>}
              </legend>
              {sections.map(({ id, titleVi, descVi }) => <label key={id} className="attendance-permissions__option">
                <input type="checkbox" checked={draft.includes(id)} onChange={(event) => {
                  const checked = event.target.checked;
                  setNotice('');
                  setDraft((current) => checked ? [...current, id] : current.filter((item) => item !== id));
                }} />
                <span><strong>{id === 'attendance:delete' ? 'Kho lưu trữ' : titleVi}</strong><small>{descVi}</small></span>
              </label>)}
            </fieldset>
            <footer>
              <p role="status">{notice}</p>
              <button type="submit" disabled={saving || !dirty}>{saving ? 'Đang lưu…' : 'Lưu quyền'}</button>
            </footer>
          </form>}
        </div>
      )}
    </section>
  );
}
