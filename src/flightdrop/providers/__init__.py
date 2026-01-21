from flightdrop.providers.base import BaseProvider, ProviderError
from flightdrop.providers.amadeus import AmadeusProvider


def get_provider(name: str) -> BaseProvider:
    normalized = name.lower()
    if normalized == "amadeus":
        return AmadeusProvider()
    raise ProviderError(f"Unknown provider: {name}")
