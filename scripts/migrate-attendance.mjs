import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const sourceRef = 'xpkbgqdlfonsinriggmj';
const targetRef = 'btgxeaakwjtlfvgiexzp';
const proofBucket = 'attendance-session-proofs';
const apply = process.argv[2] === '--apply';

const profileUser = `(
  exists (select 1 from public.profiles p where p.id = u.id)
  or exists (select 1 from public.system_roles r where r.user_id = u.id and r.scope = 'system')
)`;
const scopedUserIds = `select u.id from auth.users u where ${profileUser}`;
const users = {
  table: 'auth.users',
  where: profileUser,
  columns: [
    'instance_id', 'id', 'aud', 'role', 'email', 'encrypted_password',
    'email_confirmed_at', 'last_sign_in_at', 'raw_app_meta_data',
    'raw_user_meta_data', 'created_at', 'updated_at', 'phone',
    'phone_confirmed_at', 'banned_until', 'is_sso_user', 'deleted_at', 'is_anonymous',
  ],
  literals: ["'' as confirmation_token", "'' as recovery_token", "'' as email_change",
    "'' as email_change_token_new"],
};
const identities = {
  table: 'auth.identities',
  where: `u.user_id in (${scopedUserIds})`,
  columns: ['id', 'provider_id', 'user_id', 'identity_data', 'provider',
    'last_sign_in_at', 'created_at', 'updated_at'],
};

const tables = [
  users, identities,
  ...[
    'profiles', 'system_roles',
    'bes_extra_classes', 'bes_extra_class_members', 'bes_extra_class_teachers',
    'bes_extra_attendance_sessions', 'bes_extra_attendance_records',
    'bes_extra_attendance_record_changes', 'bes_attendance_access_settings',
    'bes_supplemental_students', 'bes_supplemental_groups',
    'bes_supplemental_group_memberships', 'bes_supplemental_group_teachers',
    'bes_supplemental_sessions', 'bes_supplemental_session_participants',
    'bes_supplemental_attendance_record_changes', 'bes_attendance_archive',
    'bes_extra_class_archive',
  ].map((name) => ({ table: `public.${name}`, where: name === 'system_roles' ? "u.scope = 'system'" : 'true' })),
];
const sequences = ['bes_extra_attendance_record_changes', 'bes_supplemental_attendance_record_changes'];

function connection(variable, projectRef) {
  const url = new URL(process.env[variable] ?? 'postgresql://invalid');
  const user = decodeURIComponent(url.username);
  const direct = url.hostname === `db.${projectRef}.supabase.co` && user === 'postgres';
  const pooled = /^[a-z0-9.-]+\.pooler\.supabase\.com$/.test(url.hostname) && user === `postgres.${projectRef}`;
  if (!['postgresql:', 'postgres:'].includes(url.protocol)
      || (!direct && !pooled) || (url.port && url.port !== '5432')
      || url.pathname !== '/postgres' || !url.password || url.hash) {
    throw Error(`${variable} needs the Direct or Session pooler URI for project ${projectRef}.`);
  }
  const parameters = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('PG')));
  for (const key of Object.keys(parameters)) {
    if (/^ATTENDANCE_(SOURCE|TARGET)_/.test(key)) delete parameters[key];
  }
  return {
    ...parameters, PGHOST: url.hostname, PGPORT: '5432', PGDATABASE: 'postgres',
    PGUSER: user, PGPASSWORD: decodeURIComponent(url.password), PGSSLMODE: 'verify-full',
    PGSSLROOTCERT: process.env[`${variable}_CA`] || process.env.PGSSLROOTCERT || 'system',
    PGCONNECT_TIMEOUT: '10',
  };
}

function sql(env, input, label) {
  return new Promise((resolve, reject) => {
    const child = spawn('psql', ['-X', '-qAtw', '-v', 'ON_ERROR_STOP=1'], {
      env, stdio: ['pipe', 'pipe', 'pipe'],
    });
    const chunks = [];
    child.stdout.on('data', (chunk) => chunks.push(chunk));
    // Database errors can include row values. Keep stderr out of reports.
    child.stderr.resume();
    child.stdin.on('error', () => {});
    child.on('error', () => reject(Error('Install PostgreSQL client tools (psql) first.')));
    child.on('close', (code) => {
      if (code === 0) resolve(Buffer.concat(chunks).toString('utf8').trim());
      else reject(Error(`${label} failed (psql exit ${code}). Check the connection, TLS, and migration prerequisites.`));
    });
    child.stdin.end(input);
  });
}

const authTokenColumns = ['confirmation_token', 'recovery_token', 'email_change', 'email_change_token_new'];

function columnNames(entry) {
  return entry === users ? [...entry.columns, ...authTokenColumns] : entry.columns;
}

function sourceCopy(entry, index) {
  const fields = entry.columns
    ? [...entry.columns.map((name) => `u.${name}`), ...(entry.literals ?? [])].join(', ')
    : 'u.*';
  return `copy (
    select ${index}, encode(convert_to(to_jsonb(r)::text, 'UTF8'), 'hex')
    from (select ${fields} from ${entry.table} u where ${entry.where}) r
  ) to stdout;`;
}

function snapshot(output) {
  const lines = output ? output.split('\n') : [];
  const counts = tables.map(() => 0);
  const names = [];
  const data = [];
  for (const line of lines) {
    const match = /^(\d+)\t([0-9a-f]+)$/.exec(line);
    if (!match) throw Error('Source returned an unexpected snapshot format.');
    const tableIndex = Number(match[1]);
    if (tableIndex === tables.length) {
      names.push(Buffer.from(match[2], 'hex').toString('utf8'));
      continue;
    }
    if (!(tableIndex in counts)) throw Error('Source returned an unexpected table index.');
    ++counts[tableIndex];
    data.push(line);
  }
  if (!counts[tables.findIndex(({table}) => table === 'public.bes_extra_classes')]) {
    throw Error('Source contains no attendance classes.');
  }
  return { data, counts, names };
}

function targetImport(entry, index, count) {
  const names = columnNames(entry);
  const columns = names?.join(', ');
  const fields = names?.map((name) => `u.${name}`).join(', ') ?? 'u.*';
  return `do $migration$
  begin
    if not exists (select 1 from ${entry.table}) then
      insert into ${entry.table} ${columns ? `(${columns})` : ''}
      select ${fields}
      from pg_temp.attendance_import d
      cross join lateral jsonb_populate_record(null::${entry.table}, d.document) u
      where d.source_table = ${index};
    end if;
    if (select count(*) from ${entry.table}) <> ${count}
      or exists (
        (select to_jsonb(r) from (select ${fields} from ${entry.table} u) r)
        except all
        (select document from pg_temp.attendance_import where source_table = ${index})
      ) then
      raise exception 'Snapshot differs for ${entry.table}; rolling back';
    end if;
  end;
  $migration$;`;
}

function storageClient(ref, variable) {
  const key = process.env[variable];
  if (!key) throw Error(`Set ${variable} locally before copying proofs.`);
  return createClient(`https://${ref}.supabase.co`, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  }).storage;
}

async function download(bucket, name) {
  const { data, error } = await bucket.download(name);
  if (!error && data) return data;
  const status = String(error?.statusCode ?? error?.status ?? '');
  if (['404', 'NoSuchKey'].includes(status)
      || (status === '400' && /^object not found$/i.test(error?.message ?? ''))) return null;
  throw Error('Could not read a proof file. Check access to the private bucket.');
}

async function hash(blob) {
  return createHash('sha256').update(Buffer.from(await blob.arrayBuffer())).digest('hex');
}

async function copyProofs(names) {
  if (!names.length) return;
  const origin = storageClient(sourceRef, 'ATTENDANCE_SOURCE_STORAGE_KEY');
  const destination = storageClient(targetRef, 'ATTENDANCE_TARGET_STORAGE_KEY');
  for (const storage of [origin, destination]) {
    const { data, error } = await storage.getBucket(proofBucket);
    if (error || data?.public !== false) throw Error('Both attendance proof buckets must exist and be private.');
  }
  const source = origin.from(proofBucket);
  const target = destination.from(proofBucket);
  for (const name of names) {
    const object = await download(source, name);
    if (!object) throw Error('A source proof file was missing. No database rows have been imported.');
    const existing = await download(target, name);
    if (!existing) {
      const { error } = await target.upload(name, object, { upsert: false, contentType: object.type });
      if (error) throw Error('A proof upload failed. Previously copied proofs remain private.');
    }
    const saved = existing ?? await download(target, name);
    if (!saved || (await hash(object)) !== (await hash(saved))) {
      throw Error('A proof checksum differed. No existing proof was replaced.');
    }
  }
}

async function main() {
  if (process.argv.length > (apply ? 3 : 2)) throw Error('Usage: node scripts/migrate-attendance.mjs [--apply]');
  const source = connection('ATTENDANCE_SOURCE_DB_URL', sourceRef);
  const target = connection('ATTENDANCE_TARGET_DB_URL', targetRef);
  const settings = "set timezone = 'UTC'; set datestyle = 'ISO, YMD'; set intervalstyle = 'postgres';";
  const proofList = `copy (select ${tables.length}, encode(convert_to(name, 'UTF8'), 'hex')
    from storage.objects where bucket_id = '${proofBucket}' order by name) to stdout;`;
  const targetCounts = tables.map(({table}, i) => `select ${i}, count(*) from ${table}`).join(' union all ');
  const sourceCounts = tables.map(({table, where}, i) => `select ${i}, count(*) from ${table} u where ${where}`)
    .concat(`select ${tables.length}, count(*) from storage.objects where bucket_id = '${proofBucket}'`).join(' union all ');
  const [rows, destinationCounts] = await Promise.all([
    sql(source, `begin isolation level repeatable read read only; ${settings}
      ${apply ? `${tables.map(sourceCopy).join('\n')}\n${proofList}` : `${sourceCounts};`}
      commit;`, 'Read source snapshot'),
    sql(target, `${targetCounts};`, 'Check destination tables'),
  ]);
  const sourceByTable = apply ? null : new Map(rows.split('\n').map((line) => line.split('|').map(Number)));
  const { data, counts, names } = apply ? snapshot(rows) : {
    counts: tables.map((_, index) => sourceByTable.get(index)), names: [],
  };
  const targetByTable = new Map(destinationCounts.split('\n').map((line) => line.split('|').map(Number)));
  if (targetByTable.size !== tables.length || counts.some((count) => !Number.isSafeInteger(count))) {
    throw Error('The projects returned an unexpected inventory.');
  }
  console.table(tables.map(({table}, index) => ({ table, source: counts[index], destination: targetByTable.get(index) })));
  const proofCount = apply ? names.length : sourceByTable.get(tables.length);
  if (!Number.isSafeInteger(proofCount)) throw Error('Unexpected proof inventory.');
  console.log(`${proofCount} files in the private proof bucket.`);
  if (!apply) return;
  const empty = [...targetByTable.values()].every((count) => count === 0);
  const sameCounts = counts.every((count, index) => targetByTable.get(index) === count);
  if (!empty && !sameCounts) throw Error('Destination already has different data. No rows or files were copied.');

  await copyProofs(names);
  const modeCheck = empty ? `do $guard$ begin
    if exists (${tables.map(({table}) => `select 1 from ${table}`).join(' union all ')})
    then raise exception 'Destination is no longer empty'; end if;
  end; $guard$;` : '';
  await sql(target, `begin; ${settings} set local lock_timeout = '5s';
    lock table ${tables.map(({table}) => table).join(', ')} in share row exclusive mode;
    ${modeCheck}
    create temporary table attendance_import_bytes(source_table int, bytes text) on commit drop;
    copy attendance_import_bytes from stdin;
${data.join('\n')}
\\.
    create temporary table attendance_import on commit drop as
      select source_table, convert_from(decode(bytes, 'hex'), 'UTF8')::jsonb document
      from attendance_import_bytes;
    ${tables.map((entry, index) => targetImport(entry, index, counts[index])).join('\n')}
    ${sequences.map((table) => `do $seq$ begin
      execute format('alter sequence public.${table}_id_seq restart with %s',
        greatest(coalesce((select max(id) + 1 from public.${table}), 1),
          (select last_value + is_called::int from public.${table}_id_seq)));
    end; $seq$;`).join('\n')}
    commit;`, 'Import and verify destination');
  console.log('Database snapshot matches the source. Proof files verified by SHA-256.');
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : 'Attendance migration failed.');
  process.exitCode = 1;
});
