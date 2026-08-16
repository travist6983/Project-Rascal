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
from typing import Protocol

import httpx

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError

log = logging.getLogger("rascal.mail")


@dataclass(frozen=True)
class Message:
    """One email. `html` is optional because a plain-text-only message is a complete one."""

    to: str
    subject: str
    text: str
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


class PostmarkProvider:
    """One HTTP call, a timeout, and exactly one retry.

    **One retry, not a backoff ladder.** The failures this can recover from are a dropped
    connection and a single 5xx; anything more persistent is an outage, and a request handler
    holding a connection open through three sleeps is worse than a caller that learns quickly
    that the send failed. Retrying a 4xx is never right — the message is malformed, and
    sending it again produces the same answer more slowly.
    """

    name = "postmark"
    endpoint = "https://api.postmarkapp.com/email"

    async def deliver(self, message: Message, settings: Settings) -> str:
        if not settings.mail_api_key:
            raise MailDeliveryError("MAIL_PROVIDER is postmark but MAIL_API_KEY is unset.")

        payload = {
            "From": settings.mail_from,
            "To": message.to,
            "Subject": message.subject,
            "TextBody": message.text,
            "MessageStream": "outbound",
        }
        if message.html:
            payload["HtmlBody"] = message.html
        if settings.mail_reply_to:
            payload["ReplyTo"] = settings.mail_reply_to

        headers = {
            "X-Postmark-Server-Token": settings.mail_api_key,
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
                    return str(response.json().get("MessageID", ""))

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
    "postmark": PostmarkProvider(),
}


def provider_for(settings: Settings) -> MailProvider:
    return _PROVIDERS[settings.mail_provider]


async def send(
    settings: Settings,
    to: str,
    subject: str,
    text: str,
    html: str | None = None,
) -> str:
    """Send one message and return the provider's id. Raises `MailDeliveryError` on failure.

    Whether this address *should* be written to — consent, deliverability, whether the account
    still exists — is decided before you get here. Ask this to send and it sends.
    """
    if not to or "@" not in to:
        raise MailDeliveryError("A recipient address is required.")

    message = Message(to=to, subject=subject, text=text, html=html)
    chosen = provider_for(settings)
    message_id = await chosen.deliver(message, settings)
    # No recipient in the log. An address in a log line is the address leaving the system by a
    # path nobody audited, and the message id is what an investigation actually needs.
    log.info(
        "mail sent",
        extra={"provider": chosen.name, "message_id": message_id, "subject": subject},
    )
    return message_id


__all__ = [
    "ConsoleProvider",
    "MailDeliveryError",
    "MailProvider",
    "Message",
    "PostmarkProvider",
    "provider_for",
    "send",
]
