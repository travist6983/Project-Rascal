/**
 * A push notification shown inside the UI — used to ask for permission honestly.
 */
export interface NotificationPreviewProps {
  time?: string;
  /** The actual push copy. One prompt, no marketing. */
  body: string;
  style?: React.CSSProperties;
}
export function NotificationPreview(props: NotificationPreviewProps): JSX.Element;
