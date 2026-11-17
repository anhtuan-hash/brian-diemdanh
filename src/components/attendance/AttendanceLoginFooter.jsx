import React from 'react';
import { Building2, GraduationCap, Landmark, Phone, ShieldCheck } from 'lucide-react';
import departmentLogo from '../../assets/hcmc-department-education.png';
import schoolLogo from '../../assets/petrus-ky-school-logo.png';
import cambridgeLogo from '../../assets/university-of-cambridge-logo.png';

export default function AttendanceLoginFooter() {
  return (
    <footer className="attendance-login-footer" lang="en">
      <div className="attendance-login-footer__grid">
        <div className="attendance-login-footer__identity">
          <div className="attendance-login-footer__logos">
            <img src={departmentLogo} alt="Ho Chi Minh City Department of Education and Training" width="132" height="132" />
            <img src={schoolLogo} alt="Pétrus Ký School" width="192" height="192" />
            <img src={cambridgeLogo} alt="University of Cambridge" width="320" height="320" />
          </div>
        </div>

        <section>
          <h2>Mr Nguyễn Anh Tuấn</h2>
          <ul className="attendance-login-footer__profile">
            <li><Landmark aria-hidden="true" /><span>Pétrus Ký Primary and Secondary School</span></li>
            <li><GraduationCap aria-hidden="true" /><span>Head of the English Department</span></li>
            <li><Phone aria-hidden="true" /><a href="tel:+84339270798">0339 270798</a></li>
            <li><Building2 aria-hidden="true" /><span>Cambridge English Exam Centre VN070</span></li>
            <li><ShieldCheck aria-hidden="true" /><span>Speaking Examiner for Cambridge English Qualifications</span></li>
          </ul>
        </section>

        <section>
          <h2>Academic Qualifications</h2>
          <ul className="attendance-login-footer__credentials" role="list">
            <li>BA in English Language</li>
            <li>Postgraduate Diploma in Educational Management and Leadership (UK)</li>
            <li>Master’s in TESOL</li>
            <li>Master’s in Educational Management</li>
            <li>Master’s in English Language Studies (in progress)</li>
          </ul>
        </section>
      </div>

      <p className="attendance-login-footer__bar">
        Designed &amp; developed by <strong>Nguyễn Anh Tuấn</strong>
      </p>
    </footer>
  );
}
