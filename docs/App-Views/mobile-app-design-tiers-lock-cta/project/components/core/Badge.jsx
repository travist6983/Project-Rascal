import React from 'react';

const KIND = {
  photo:    { bg: 'var(--rascal-peach-badge)', fg: 'var(--rascal-terracotta)', label: 'PHOTO' },
  voice:    { bg: 'var(--rascal-peach-badge)', fg: 'var(--rascal-terracotta)', label: 'VOICE' },
  question: { bg: 'var(--rascal-lav-badge)',   fg: 'var(--rascal-peri)',       label: 'QUESTION' },
  wrote:    { bg: 'var(--rascal-lav-badge)',   fg: 'var(--rascal-peri)',       label: 'WROTE IT' },
  did:      { bg: 'var(--rascal-sage)',        fg: 'var(--rascal-sage-ink)',   label: 'DID IT' }
};

export function Badge({ kind = 'photo', children, bare, style }) {
  const k = KIND[kind] || KIND.photo;
  return (
    <span style={{
      display: 'inline-block',
      padding: bare ? 0 : '6px 13px',
      borderRadius: 'var(--rascal-radius-pill)',
      background: bare ? 'transparent' : k.bg,
      color: k.fg,
      fontFamily: 'var(--rascal-font-display)',
      fontWeight: 700,
      fontSize: bare ? 11 : 'var(--rascal-app-size-badge)',
      letterSpacing: 'var(--rascal-tracking-badge)',
      ...style
    }}>{children || k.label}</span>
  );
}
