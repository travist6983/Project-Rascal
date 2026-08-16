One pill button, five tones — use it for every action; never hand-roll a button.

```jsx
<Button tone="primary" onClick={save}>Record it</Button>
<Button tone="quiet" block={false}>Not tonight</Button>
```

`tone="primary"` is terracotta and there is **one per screen**. `written` is the
periwinkle variant, used only when the action produces text. `dark` exists for
Sign in with Apple (pass `radius="14px"` there — OS chrome isn't a pill).
Disabled fills warm gray `#D9CFC2` and keeps its label color. Press scales to
0.98 over 150ms; there is no hover color change and no ripple.
