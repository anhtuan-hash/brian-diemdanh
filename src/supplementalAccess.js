import './styles/SupplementalClasses.css';
import { isAdminRole } from './utils/roles.js';

function allowedPermissionSet(profile = null) {
  const raw = profile?.permissions?.allowed;
  if (Array.isArray(raw)) {
    return new Set(raw.map((value) => String(value || '').trim()).filter(Boolean));
  }
  if (raw && typeof raw === 'object') {
    return new Set(Object.entries(raw)
      .filter(([, enabled]) => enabled === true)
      .map(([key]) => String(key || '').trim())
      .filter(Boolean));
  }
  return new Set();
}

export function canManageSupplementalLearning(runtime = {}) {
  const profile = runtime?.profile || null;
  const userId = String(profile?.id || runtime?.user?.id || '').toLowerCase();
  const approved = profile?.approved === true;
  if (!approved || !userId) return false;

  return isAdminRole(profile.role) || allowedPermissionSet(profile).has(
    profile.attendancePermissionsManaged ? 'attendance:supplemental' : 'attendance:manage',
  );
}

export function supplementalAccessSnapshot(runtime = {}) {
  return {
    allowed: canManageSupplementalLearning(runtime),
    approved: runtime?.profile?.approved === true,
    profileId: runtime?.profile?.id || runtime?.user?.id || '',
  };
}
