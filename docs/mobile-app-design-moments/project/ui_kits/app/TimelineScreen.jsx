import React from 'react';
import { AgeChip } from '../../components/app/AgeChip.jsx';
import { EyebrowLabel } from '../../components/core/EyebrowLabel.jsx';
import { TimelineEntry } from '../../components/app/TimelineEntry.jsx';

/* INFERRED SCREEN — no source screenshot. See README.md. */
export function TimelineScreen({ child = 'Milo', age = '4y 2m', entries = [] }) {
  return (
    <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '70px 22px 110px' }}>
      <h2 style={{ margin: 0, fontFamily: 'var(--rascal-font-display)', fontWeight: 800, fontSize: 'var(--rascal-app-size-screen)', letterSpacing: 'var(--rascal-tracking-display)', color: 'var(--rascal-ink)' }}>{child}'s timeline</h2>
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, margin: '6px 0 26px' }}>
        <span style={{ fontFamily: 'var(--rascal-font-body)', fontSize: 15, color: 'var(--rascal-muted)' }}>{entries.length} {entries.length === 1 ? 'entry' : 'entries'}</span>
        <AgeChip>{age} today</AgeChip>
      </div>

      <EyebrowLabel style={{ margin: '0 0 12px' }}>August 2026</EyebrowLabel>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
        {entries.map((e, i) => (
          <TimelineEntry key={i} date={e.date} age={e.age} kind={e.kind} prompt={e.prompt} artifact={e.artifact} live={i === 0} />
        ))}
      </div>
      <p style={{ margin: '24px 4px 0', fontFamily: 'var(--rascal-font-body)', fontSize: 14, lineHeight: 1.5, color: 'var(--rascal-muted)', textWrap: 'pretty' }}>
        Scroll down far enough and he gets younger. That's the whole point.
      </p>
    </div>
  );
}
