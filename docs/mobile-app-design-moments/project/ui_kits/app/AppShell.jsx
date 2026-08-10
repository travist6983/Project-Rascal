import React from 'react';

export function AppShell({ children, statusDark }) {
  const ink = statusDark ? 'var(--rascal-canvas)' : 'var(--rascal-ink)';
  return (
    <div style={{ position: 'relative', width: 413, height: 872, padding: 10, borderRadius: 56, background: 'var(--rascal-ink)', boxShadow: '0 24px 60px rgba(0,0,0,.22), 0 3px 10px rgba(0,0,0,.12)', flex: 'none' }}>
      <div style={{
        position: 'relative', width: 393, height: 852, borderRadius: 47, overflow: 'hidden',
        backgroundColor: 'var(--rascal-canvas)', backgroundImage: 'var(--rascal-grain)',
        display: 'flex', flexDirection: 'column'
      }}>
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 54, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 30px 0 34px', zIndex: 40, pointerEvents: 'none' }}>
          <span style={{ fontFamily: 'var(--rascal-font-body)', fontWeight: 600, fontSize: 16, color: ink }}>9:04</span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ display: 'flex', alignItems: 'flex-end', gap: 2, height: 11 }}>
              {[4, 6, 8, 11].map(h => <span key={h} style={{ width: 3, height: h, borderRadius: 1, background: ink }} />)}
            </span>
            <span style={{ width: 15, height: 11, borderRadius: 2, border: '1.4px solid ' + ink, position: 'relative', display: 'inline-block' }}>
              <span style={{ position: 'absolute', inset: 1.4, background: ink, borderRadius: 1 }} />
            </span>
          </span>
        </div>
        <div style={{ position: 'absolute', top: 20, left: '50%', transform: 'translateX(-50%)', width: 118, height: 33, borderRadius: 20, background: 'var(--rascal-ink)', zIndex: 45 }} />
        {children}
      </div>
    </div>
  );
}
