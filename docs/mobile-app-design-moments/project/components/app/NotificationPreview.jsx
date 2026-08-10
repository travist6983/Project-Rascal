import React from 'react';
import { Card } from '../core/Card.jsx';

export function NotificationPreview({ time = '7:00am', body, style }) {
  return (
    <Card padding="18px 20px" radius="var(--rascal-radius-card)" style={style}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 9 }}>
        <span style={{
          width: 22, height: 22, borderRadius: 6, background: 'var(--rascal-terracotta)',
          display: 'grid', placeItems: 'center',
          fontFamily: 'var(--rascal-font-display)', fontWeight: 800, fontSize: 13, color: 'var(--rascal-canvas)'
        }}>R</span>
        <span style={{ fontFamily: 'var(--rascal-font-body)', fontWeight: 600, fontSize: 12, letterSpacing: 'var(--rascal-tracking-eyebrow)', textTransform: 'uppercase', color: 'var(--rascal-muted)' }}>Rascal</span>
        <span style={{ marginLeft: 'auto', fontFamily: 'var(--rascal-font-body)', fontSize: 12, color: 'var(--rascal-muted)' }}>{time}</span>
      </div>
      <p style={{ margin: 0, fontFamily: 'var(--rascal-font-display)', fontWeight: 700, fontSize: 16, lineHeight: 1.35, color: 'var(--rascal-ink)' }}>{body}</p>
    </Card>
  );
}
