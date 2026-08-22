import React from 'react';
import { Badge } from '../core/Badge.jsx';
import { Button } from '../core/Button.jsx';
import { Card } from '../core/Card.jsx';

const TINT = { photo: 'peach', voice: 'peach', question: 'lavender', wrote: 'lavender', did: 'sage' };

export function PromptCard({ kind = 'photo', prompt, cta, onAction, compact, style }) {
  const written = kind === 'question' || kind === 'wrote';
  return (
    <Card
      tint={TINT[kind] || 'peach'}
      radius="var(--rascal-radius-app-card)"
      padding={compact ? 15 : 22}
      style={style}
    >
      <Badge kind={kind} />
      <p style={{
        margin: compact ? '8px 0 0' : '14px 0 16px',
        fontFamily: 'var(--rascal-font-display)',
        fontWeight: 'var(--rascal-weight-prompt)',
        fontSize: compact ? 14 : 'var(--rascal-app-size-prompt)',
        lineHeight: 'var(--rascal-leading-prompt)',
        letterSpacing: compact ? 0 : 'var(--rascal-tracking-prompt)',
        color: 'var(--rascal-ink)',
        textWrap: 'pretty'
      }}>{prompt}</p>
      {!compact && cta ? (
        <Button tone={written ? 'written' : 'primary'} size="md" onClick={onAction}>{cta}</Button>
      ) : null}
    </Card>
  );
}
