import React from 'react';
import { Card } from '../../components/core/Card.jsx';
import { EyebrowLabel } from '../../components/core/EyebrowLabel.jsx';
import { NotificationPreview } from '../../components/app/NotificationPreview.jsx';
import { Wordmark } from '../../components/core/Wordmark.jsx';

/* INFERRED SCREEN — no source screenshot. See README.md. */
function Row({ label, value, last }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '16px 18px', borderBottom: last ? 'none' : '1px solid var(--rascal-border)' }}>
      <span style={{ fontFamily: 'var(--rascal-font-body)', fontSize: 16, color: 'var(--rascal-ink)' }}>{label}</span>
      <span style={{ fontFamily: 'var(--rascal-font-body)', fontSize: 16, color: 'var(--rascal-muted)' }}>{value}</span>
    </div>
  );
}

export function Settings({ child = 'Milo', birth = 'Jun 12, 2022' }) {
  return (
    <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '70px 22px 110px' }}>
      <h2 style={{ margin: '0 0 26px', fontFamily: 'var(--rascal-font-display)', fontWeight: 800, fontSize: 'var(--rascal-app-size-screen)', letterSpacing: 'var(--rascal-tracking-display)', color: 'var(--rascal-ink)' }}>Settings</h2>

      <EyebrowLabel style={{ margin: '0 0 10px' }}>Him</EyebrowLabel>
      <Card padding={0} style={{ marginBottom: 26 }}>
        <Row label="Name" value={child} />
        <Row label="Born" value={birth} />
        <Row label="Age today" value="4y 2m" last />
      </Card>

      <EyebrowLabel style={{ margin: '0 0 10px' }}>The morning nudge</EyebrowLabel>
      <NotificationPreview body={'Today: photograph the mess ' + child + ' made. Don\'t clean it up first.'} style={{ marginBottom: 10 }} />
      <p style={{ margin: '0 0 26px', padding: '0 4px', fontFamily: 'var(--rascal-font-body)', fontSize: 14, lineHeight: 1.5, color: 'var(--rascal-muted)', textWrap: 'pretty' }}>
        One a day, at 7:00am. There is no second nudge, and nothing counts how many you answered.
      </p>

      <EyebrowLabel style={{ margin: '0 0 10px' }}>His archive</EyebrowLabel>
      <Card padding={0} style={{ marginBottom: 26 }}>
        <Row label="Signed in" value="Apple · you@icloud.com" />
        <Row label="Recordings" value="On this phone + archive" />
        <Row label="Export everything" value="&#8250;" last />
      </Card>

      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, padding: '0 4px' }}>
        <Wordmark size={15} />
        <span style={{ fontFamily: 'var(--rascal-font-mono)', fontSize: 12, color: 'var(--rascal-muted)' }}>2.0.1</span>
      </div>
    </div>
  );
}
