import React from 'react';
import { Button } from '../../components/core/Button.jsx';
import { EyebrowLabel } from '../../components/core/EyebrowLabel.jsx';
import { RecordButton } from '../../components/app/RecordButton.jsx';
import { WaveformMeter } from '../../components/app/WaveformMeter.jsx';

export function Capture({ prompt, recording, elapsed = 0, hasTake, onToggle, onKeep, onCancel }) {
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '88px 26px 0' }}>
      <EyebrowLabel>{recording ? 'Recording' : hasTake ? 'Take one' : 'Ready'}</EyebrowLabel>
      <p style={{ margin: '10px 0 34px', textAlign: 'center', fontFamily: 'var(--rascal-font-display)', fontWeight: 700, fontSize: 'var(--rascal-app-size-prompt)', lineHeight: 1.3, color: 'var(--rascal-ink)', maxWidth: '15em', textWrap: 'pretty' }}>{prompt}</p>

      <WaveformMeter active={recording} style={{ marginBottom: 20 }} />
      <p style={{ margin: '0 0 auto', fontFamily: 'var(--rascal-font-mono)', fontSize: 34, fontVariantNumeric: 'tabular-nums', color: 'var(--rascal-ink)' }}>
        0:{String(elapsed).padStart(2, '0')}
      </p>

      <RecordButton recording={recording} onClick={onToggle} />
      <p style={{ margin: '16px 0 12px', fontFamily: 'var(--rascal-font-body)', fontSize: 15, color: 'var(--rascal-muted)' }}>
        {recording ? 'Tap to stop. Hold the phone near him.' : hasTake ? 'Kept on this phone until you save it.' : 'One hand is enough. Tap the circle.'}
      </p>
      <div style={{ width: '100%', paddingBottom: 34 }}>
        {hasTake && !recording
          ? <Button onClick={onKeep}>Keep it</Button>
          : <Button tone="quiet" onClick={onCancel}>Not tonight</Button>}
      </div>
    </div>
  );
}
