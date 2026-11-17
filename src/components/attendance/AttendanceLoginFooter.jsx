import React from 'react';
import { Building2, GraduationCap, Heart, Landmark, Monitor, Phone, ShieldCheck } from 'lucide-react';
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
          <p>Better Learners ·<br />Brighter Futures</p>
        </div>

        <section>
          <h2>Mr Nguyễn Anh Tuấn</h2>
          <ul className="attendance-login-footer__profile">
            <li><Landmark aria-hidden="true" /><span>Pétrus Ký Primary and Secondary School</span></li>
            <li><GraduationCap aria-hidden="true" /><span>Head of the English Department</span></li>
            <li><Phone aria-hidden="true" /><a href="tel:+84339270798">0339 270798</a></li>
            <li><Building2 aria-hidden="true" /><span>Authorised Cambridge English Exam Centre VN070 · Ho Chi Minh City Department of Education and Training</span></li>
            <li><ShieldCheck aria-hidden="true" /><span>Speaking Examiner for Cambridge English Qualifications</span></li>
          </ul>
        </section>

        <section>
          <h2>Academic Qualifications &amp; Professional Credentials</h2>
          <ul className="attendance-login-footer__credentials" role="list">
            <li>Bachelor’s degree in English Language</li>
            <li>Postgraduate Diploma in Educational Management and Leadership (UK)</li>
            <li>Master’s degree in Teaching English to Speakers of Other Languages (TESOL)</li>
            <li>Master’s degree in Educational Management</li>
            <li>Currently pursuing a master’s degree in English Language Studies</li>
          </ul>
        </section>
      </div>

      <div className="attendance-login-footer__bar">
        <div className="attendance-login-footer__signature">
          <img src={schoolLogo} alt="" width="192" height="192" />
          <strong>Pétrus Ký School System</strong>
          <span>Teach Better Together <Heart aria-hidden="true" /></span>
        </div>
        <p><Monitor aria-hidden="true" /><span>Designed &amp; developed by <strong>Nguyễn Anh Tuấn</strong></span></p>
      </div>
    </footer>
  );
}
