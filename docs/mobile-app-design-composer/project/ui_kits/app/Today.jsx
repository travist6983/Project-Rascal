import React from 'react';
import { EyebrowLabel } from '../../components/core/EyebrowLabel.jsx';
import { PromptCard } from '../../components/app/PromptCard.jsx';
import { TimelineEntry } from '../../components/app/TimelineEntry.jsx';

export function Today({ child = 'Milo', age = '4y 2m', entries = [], onCapture, onWrite }) {
  return (
    <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '70px 22px 110px' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
        <div>
          <h2 style={{ margin: 0, fontFamily: 'var(--rascal-font-display)', fontWeight: 800, fontSize: 'var(--rascal-app-size-title)', letterSpacing: 'var(--rascal-tracking-display)', color: 'var(--rascal-ink)' }}>Rascal</h2>
          <p style={{ margin: '2px 0 0', fontFamily: 'var(--rascal-font-body)', fontSize: 16, color: 'var(--rascal-muted)' }}>{child} · {age}</p>
        </div>
        <span style={{ width: 42, height: 42, borderRadius: 'var(--rascal-radius-pill)', border: '1px solid var(--rascal-border)', background: 'var(--rascal-surface)', display: 'grid', placeItems: 'center', fontSize: 17, color: 'var(--rascal-muted)' }}>&#10227;</span>
      </div>

      <EyebrowLabel style={{ margin: '22px 0 10px' }}>Today</EyebrowLabel>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <PromptCard kind="photo" cta="Capture it" onAction={onCapture}
          prompt={'Take a photo of him sleeping.'} />
        <PromptCard kind="question" cta="Write it" onAction={onWrite}
          prompt={"What's the thing he does that nobody else would notice?"} />
      </div>

      {entries.length ? (
        <>
          <EyebrowLabel style={{ margin: '24px 0 10px' }}>{entries[0].label || 'Yesterday'}</EyebrowLabel>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            {entries.map((e, i) => (
              <TimelineEntry key={i} date={e.date} age={e.age} kind={e.kind} prompt={e.prompt} artifact={e.artifact} live={i === 0} settle={e.settle} />
            ))}
          </div>
        </>
      ) : null}

      <p style={{ margin: '20px 4px 0', fontFamily: 'var(--rascal-font-body)', fontSize: 14, lineHeight: 1.5, color: 'var(--rascal-muted)' }}>
        {entries.length ? 'One down. Tomorrow morning: something about his voice.' : 'Nothing saved yet. Start with either one.'}
      </p>
    </div>
  );
}
