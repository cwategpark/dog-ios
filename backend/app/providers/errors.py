class DomainValidationError(ValueError):
    """The request or trusted catalog does not satisfy a business constraint."""


class ProviderNotConfigured(RuntimeError):
    """Required credentials or service configuration are absent."""


class ProviderFailure(RuntimeError):
    """A provider rejected the operation or returned an invalid result."""


class GenerationUncertain(ProviderFailure):
    """An accepted, potentially billable request has an unknown outcome; do not retry."""
