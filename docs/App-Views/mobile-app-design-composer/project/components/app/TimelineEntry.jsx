import React from 'react';
import { AgeChip } from './AgeChip.jsx';
import { Badge } from '../core/Badge.jsx';
import { Card } from '../core/Card.jsx';

export function TimelineEntry({ date, age, kind = 'photo', prompt, artifact, live, settle, lifted, style }) {
  const written = kind === 'question' || kind === 'wrote';
  return (
    <div style={{ position: 'relative', paddingLeft: 32, ...style }}>
      <div style={{ position: 'absolute', left: 6, top: 6, bottom: 0, width: 1, background: 'var(--rascal-border)' }} />
      {live ? <div style={{ position: 'absolute', left: 6, top: 6, width: 1, height: 120, background: 'var(--rascal-terracotta)' }} /> : null}
      <div style={{
        position: 'absolute', left: 0, top: 5, width: 13, height: 13, borderRadius: 'var(--rascal-radius-pill)',
        background: live ? 'var(--rascal-terracotta)' : 'var(--rascal-surface)',
        border: '1px solid ' + (live ? 'var(--rascal-terracotta)' : 'var(--rascal-border)')
      }} />
      <div style={settle ? { animation: 'rascal-settle var(--rascal-dur-settle) var(--rascal-ease-enter) both' } : undefined}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: 8 }}>
          <span style={{ fontFamily: 'var(--rascal-font-mono)', fontSize: 12, letterSpacing: '0.04em', color: 'var(--rascal-muted)', fontVariantNumeric: 'tabular-nums' }}>{date}</span>
          {age ? <AgeChip prefix="Age">{age}</AgeChip> : null}
        </div>
        <Card radius="var(--rascal-radius-card)" padding={18} lifted={lifted}>
          <Badge kind={kind} bare />
          <p style={{ margin: '9px 0 14px', fontFamily: 'var(--rascal-font-display)', fontWeight: 700, fontSize: 17, lineHeight: 1.3, color: 'var(--rascal-ink)' }}>{prompt}</p>
          {artifact ? (
            <div style={{
              display: 'flex', alignItems: 'center', gap: 12, padding: '12px 14px',
              borderRadius: 'var(--rascal-radius-md)',
              background: written ? 'var(--rascal-lav)' : 'var(--rascal-peach-deep)',
              fontFamily: 'var(--rascal-font-body)', fontSize: 14, color: 'var(--rascal-ink)'
            }}>{artifact}</div>
          ) : null}
        </Card>
      </div>
    </div>
  );
}
