/**
 * The product's core object: one day's prompt, its kind, and its single action.
 * @startingPoint section="App" subtitle="Today's prompt card, every kind" viewport="700x300"
 */
export interface PromptCardProps {
  /** Drives tint, badge, and CTA color together. Never set them apart. */
  kind?: 'photo' | 'voice' | 'question' | 'wrote' | 'did';
  /** An instruction plus a physical detail. Two sentences, second removes the excuse. */
  prompt: string;
  /** 'Record it' | 'Capture it' | 'Write it' | 'We did it'. Omit for a display-only card. */
  cta?: string;
  onAction?: () => void;
  /** Small in-context variant — no CTA, 14px prompt. For "other mornings look like this". */
  compact?: boolean;
  style?: React.CSSProperties;
}
export function PromptCard(props: PromptCardProps): JSX.Element;
