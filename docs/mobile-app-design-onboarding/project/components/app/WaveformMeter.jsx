import React from 'react';

export function WaveformMeter({ active, bars = 17, height = 96, style }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 5, height, width: '100%', ...style }}>
      {Array.from({ length: bars }, (_, i) => (
        <span key={i} style={{
          width: 6,
          height: 28 + ((i * 37) % 54),
          borderRadius: 'var(--rascal-radius-pill)',
          background: active ? 'var(--rascal-terracotta)' : '#E3D8CB',
          transformOrigin: 'center',
          transform: active ? undefined : 'scaleY(0.4)',
          animation: active ? `rascal-wave ${620 + (i % 5) * 130}ms ease-in-out ${i * 70}ms infinite` : undefined
        }} />
      ))}
    </div>
  );
}
