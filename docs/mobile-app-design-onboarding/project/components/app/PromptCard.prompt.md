One day's prompt: tint, badge, prompt, and the single action that completes it.

```jsx
<PromptCard kind="voice" prompt="Ask Milo what the best part of today was. Hold the phone and let him talk." cta="Record it" onAction={record} />
<PromptCard kind="did" prompt="Ten minutes on the floor. Nothing to save." compact />
```

`kind` drives tint, badge and CTA color as a set — passing a mismatched pair is
the most common way to break the brand. Never put two full PromptCards with
terracotta CTAs on screen; the second should be `kind="question"` or `compact`.
