"""Sending one email. Nothing else.

**This file knows nothing about lifecycle notices, auth, or consent, and that is the point of
it being its own phase.** Two unbuilt features need a mailer — phase 38's deletion warnings and
phase 57's magic link — and building it inside either one would bury a shared dependency in a
feature, so the second consumer would find a mailer shaped entirely around the first.

So: `send(to, subject, text, html=None) -> message_id`, and it raises on failure. Deciding
*whether* somebody should be emailed is the caller's job. Reading `marketing_consent`,
`transactional_consent` and `email_deliverable` is the caller's job. This just sends.

**`console` is the default provider and that is a safety property.** It writes the whole
message to stdout and never opens a socket, so a local run cannot send real mail to a real
person. The addresses this will eventually carry belong to parents and the messages are about
deleting their child's archive; "I pointed my dev box at the production key" is not a mistake
worth leaving available.

Out of scope, deliberately and per the phase: templates for lifecycle notices (that phase owns
them), unsubscribe handling, suppression lists, bounce webhooks, and the marketing list —
`decisions.md` open item 12, which is undecided and must not be built toward here.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from typing import Literal, Protocol

import httpx

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError

log = logging.getLogger("rascal.mail")


#: Which lane a message is in. **On the port rather than in a convention**, per D8a: the caller
#: cannot forget which one it is in, because there is no default to fall through to.
#:
#: The distinction is D3a's. A transactional message is a deletion warning or a sign-in link —
#: something the account needs regardless of marketing consent. A marketing message is one a
#: parent may switch off. Two senders that disagreed about which was which is the failure the
#: single port exists to prevent, so the lane travels *with* the message.
MailStream = Literal["marketing", "transactional"]


@dataclass(frozen=True)
class Message:
    """One email. `html` is optional because a plain-text-only message is a complete one."""

    to: str
    subject: str
    text: str
    stream: MailStream
    html: str | None = None


class MailDeliveryError(RascalError):
    """Sending failed. Raised rather than returned, so a caller cannot ignore it by accident.

    A `RascalError` so it renders in the one error shape if it ever reaches a handler
    unhandled — but no caller should let it: whether a failed send is a 500, a retry or a
    silent no-op is a question only the feature can answer.
    """

    def __init__(self, message: str) -> None:
        super().__init__(ErrorCode.INTERNAL_ERROR, message)


class MailProvider(Protocol):
    """What a provider has to do. One method, so adding one is small and testable."""

    name: str

    async def deliver(self, message: Message, settings: Settings) -> str:
        """Send, and return the provider's message id. Raise `MailDeliveryError` on failure."""
        ...


class ConsoleProvider:
    """Writes the message to stdout and returns a synthetic id. Never opens a socket.

    The whole body is printed rather than a summary, because the thing worth checking locally
    is the copy — a lifecycle notice that reads as a threat, or a magic link that lands in the
    wrong place, is exactly what this is for.
    """

    name = "console"

    async def deliver(self, message: Message, settings: Settings) -> str:
        message_id = f"console-{uuid.uuid4()}"
        reply_to = settings.mail_reply_to or settings.mail_from
        body = "\n".join(
            [
                "",
                "--- mail (console provider — nothing was sent) " + "-" * 32,
                f"from:     {settings.mail_from}",
                f"reply-to: {reply_to}",
                f"to:       {message.to}",
                f"stream:   {message.stream}",
                f"subject:  {message.subject}",
                f"id:       {message_id}",
                "-" * 78,
                message.text,
                *(["-" * 78, "(html alternative)", message.html] if message.html else []),
                "-" * 78,
                "",
            ]
        )
        # Printing *is* this provider's job — there is nothing else it could do.
        print(body)
        return message_id


class ResendProvider:
    """One HTTP call, a timeout, and exactly one retry.

    **This replaced the Postmark adapter rather than sitting beside it**, per D8, and the swap
    was only cheap because it had never run: `MAIL_PROVIDER` was `console` in every environment
    from phase 56 to here, so there was no delivery history and no warmed domain to carry. That
    stops being true with the first real send. What else a provider migration costs is D8's
    subject, not this file's — see `docs/decisions.md`, which is where that list belongs.

    **One retry, not a backoff ladder.** The failures this can recover from are a dropped
    connection and a single 5xx; anything more persistent is an outage, and a request handler
    holding a connection open through three sleeps is worse than a caller that learns quickly
    that the send failed. Retrying a 4xx is never right — the message is malformed, and sending
    it again produces the same answer more slowly.

    **The sandbox sender only delivers to the account owner's address.** Until a domain is
    verified with Resend, `MAIL_FROM` has to be `onboarding@resend.dev` and mail to anybody else
    is accepted and silently dropped. That is the first thing to check when a stranger reports
    getting nothing — see `docs/blocked.md` §13.
    """

    name = "resend"
    endpoint = "https://api.resend.com/emails"

    async def deliver(self, message: Message, settings: Settings) -> str:
        if not settings.mail_api_key:
            raise MailDeliveryError("MAIL_PROVIDER is resend but MAIL_API_KEY is unset.")

        payload: dict[str, object] = {
            "from": settings.mail_from,
            "to": [message.to],
            "subject": message.subject,
            "text": message.text,
            # Resend has no stream concept, so the lane rides as a header. It is not decoration:
            # a bounce investigation that cannot tell a deletion warning from a newsletter is an
            # investigation into the wrong problem.
            "headers": {"X-Entity-Ref-Stream": message.stream},
        }
        if message.html:
            payload["html"] = message.html
        if settings.mail_reply_to:
            payload["reply_to"] = settings.mail_reply_to

        headers = {
            "Authorization": f"Bearer {settings.mail_api_key}",
            "Accept": "application/json",
        }

        last: Exception | None = None
        async with httpx.AsyncClient(timeout=settings.mail_timeout_seconds) as client:
            for attempt in (1, 2):
                try:
                    response = await client.post(self.endpoint, json=payload, headers=headers)
                except httpx.HTTPError as exc:
                    last = exc
                    log.warning(
                        "mail transport failed",
                        extra={"attempt": attempt, "reason": str(exc)},
                    )
                    continue

                if response.status_code < 300:
                    return str(response.json().get("id", ""))

                # A 4xx will say the same thing on a second attempt, so it ends here.
                if response.status_code < 500:
                    raise MailDeliveryError(
                        f"Mail provider refused the message ({response.status_code})."
                    )

                last = MailDeliveryError(f"Mail provider error ({response.status_code}).")
                log.warning(
                    "mail provider error",
                    extra={"attempt": attempt, "status": response.status_code},
                )

        raise MailDeliveryError(f"Mail delivery failed after one retry: {last}")


_PROVIDERS: dict[str, MailProvider] = {
    "console": ConsoleProvider(),
    "resend": ResendProvider(),
}


def provider_for(settings: Settings) -> MailProvider:
    return _PROVIDERS[settings.mail_provider]


async def send(
    settings: Settings,
    to: str,
    subject: str,
    text: str,
    stream: MailStream,
    html: str | None = None,
) -> str:
    """Send one message and return the provider's id. Raises `MailDeliveryError` on failure.

    Whether this address *should* be written to — consent, deliverability, whether the account
    still exists — is decided before you get here. Ask this to send and it sends.
    """
    if not to or "@" not in to:
        raise MailDeliveryError("A recipient address is required.")

    message = Message(to=to, subject=subject, text=text, stream=stream, html=html)
    chosen = provider_for(settings)
    message_id = await chosen.deliver(message, settings)
    # No recipient in the log. An address in a log line is the address leaving the system by a
    # path nobody audited, and the message id is what an investigation actually needs.
    log.info(
        "mail sent",
        extra={
            "provider": chosen.name,
            "message_id": message_id,
            "subject": subject,
            "stream": stream,
        },
    )
    return message_id


__all__ = [
    "ConsoleProvider",
    "MailDeliveryError",
    "MailProvider",
    "MailStream",
    "Message",
    "ResendProvider",
    "provider_for",
    "send",
]
