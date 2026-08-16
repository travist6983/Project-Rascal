/**
 * One saved day on the timeline: rail node, date, age stamp, card, artifact well.
 * @startingPoint section="App" subtitle="Timeline entry with rail and age stamp" viewport="700x260"
 */
export interface TimelineEntryProps {
  /** Mono, uppercase: 'AUG 8, 2026'. */
  date: string;
  /** Long form: '4 years, 2 months'. */
  age?: string;
  kind?: 'photo' | 'voice' | 'question' | 'wrote' | 'did';
  prompt: string;
  /** What was saved: '0:34 · his voice', '1 photo saved', or the text he said. Omit for a did-it entry. */
  artifact?: React.ReactNode;
  /** Terracotta rail + filled node — the newest entry. */
  live?: boolean;
  /** Play rascal-settle on mount. Only for an entry that just landed. */
  settle?: boolean;
  lifted?: boolean;
  style?: React.CSSProperties;
}
export function TimelineEntry(props: TimelineEntryProps): JSX.Element;
