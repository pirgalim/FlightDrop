import json
import os
import time
from datetime import date, timedelta
from urllib import parse, request

from flightdrop.providers.base import BaseProvider, FlightOffer, ProviderError


class AmadeusProvider(BaseProvider):
    name = "amadeus"

    def __init__(self, client_id: str | None = None, client_secret: str | None = None) -> None:
        self.client_id = client_id or os.environ.get("AMADEUS_CLIENT_ID")
        self.client_secret = client_secret or os.environ.get("AMADEUS_CLIENT_SECRET")
        self.base_url = os.environ.get("AMADEUS_API_BASE", "https://test.api.amadeus.com")
        self._token: str | None = None
        self._token_expiry: float = 0

    def _get_token(self) -> str:
        if self._token and time.time() < self._token_expiry:
            return self._token

        if not self.client_id or not self.client_secret:
            raise ProviderError("Missing AMADEUS_CLIENT_ID or AMADEUS_CLIENT_SECRET environment variables.")

        auth_url = f"{self.base_url}/v1/security/oauth2/token"
        body = parse.urlencode(
            {
                "grant_type": "client_credentials",
                "client_id": self.client_id,
                "client_secret": self.client_secret,
            }
        ).encode("utf-8")
        req = request.Request(auth_url, data=body, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")

        try:
            with request.urlopen(req, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except Exception as exc:  # pragma: no cover - network errors
            raise ProviderError(f"Amadeus auth failed: {exc}") from exc

        token = payload.get("access_token")
        expires_in = float(payload.get("expires_in", 0))
        if not token:
            raise ProviderError("Amadeus auth did not return an access token.")

        self._token = token
        self._token_expiry = time.time() + max(expires_in - 30, 0)
        return token

    def _search_date(
        self,
        origin: str,
        destination: str,
        currency: str,
        departure_date: date,
        return_date: date | None,
    ) -> list[FlightOffer]:
        token = self._get_token()
        url = f"{self.base_url}/v2/shopping/flight-offers"
        params = {
            "originLocationCode": origin,
            "destinationLocationCode": destination,
            "departureDate": departure_date.isoformat(),
            "adults": 1,
            "currencyCode": currency,
            "max": 20,
        }
        if return_date:
            params["returnDate"] = return_date.isoformat()
        req = request.Request(f"{url}?{parse.urlencode(params)}")
        req.add_header("Authorization", f"Bearer {token}")

        try:
            with request.urlopen(req, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except Exception as exc:  # pragma: no cover - network errors
            raise ProviderError(f"Amadeus search failed: {exc}") from exc

        offers = payload.get("data", [])
        carrier_map = payload.get("dictionaries", {}).get("carriers", {})
        if not offers:
            return []

        results: list[FlightOffer] = []
        for offer in offers:
            price_info = offer.get("price", {})
            if not price_info:
                continue
            total = float(price_info.get("grandTotal", 0))
            if total <= 0:
                continue

            itineraries = offer.get("itineraries", [])
            outbound_departure = None
            outbound_arrival = None
            inbound_departure = None
            inbound_arrival = None
            carriers: list[str] = []
            if itineraries:
                outbound_segments = itineraries[0].get("segments", [])
                if outbound_segments:
                    outbound_departure = outbound_segments[0]["departure"]["at"]
                    outbound_arrival = outbound_segments[-1]["arrival"]["at"]
                    for seg in outbound_segments:
                        code = seg.get("carrierCode")
                        operating = seg.get("operating", {}).get("carrierCode")
                        for carrier_code in [code, operating]:
                            if not carrier_code:
                                continue
                            label = carrier_map.get(carrier_code)
                            formatted = label if label else carrier_code
                            if formatted not in carriers:
                                carriers.append(formatted)
                if len(itineraries) > 1:
                    inbound_segments = itineraries[1].get("segments", [])
                    if inbound_segments:
                        inbound_departure = inbound_segments[0]["departure"]["at"]
                        inbound_arrival = inbound_segments[-1]["arrival"]["at"]
                        for seg in inbound_segments:
                            code = seg.get("carrierCode")
                            operating = seg.get("operating", {}).get("carrierCode")
                        for carrier_code in [code, operating]:
                            if not carrier_code:
                                continue
                            label = carrier_map.get(carrier_code)
                            formatted = label if label else carrier_code
                            if formatted not in carriers:
                                carriers.append(formatted)

            results.append(
                FlightOffer(
                    price=total,
                    currency=currency,
                    deeplink=None,
                    outbound_departure=outbound_departure,
                    outbound_arrival=outbound_arrival,
                    inbound_departure=inbound_departure,
                    inbound_arrival=inbound_arrival,
                    carriers=tuple(carriers),
                )
            )

        results.sort(key=lambda offer: offer.price)
        return results

    def search_top(
        self,
        origin: str,
        destination: str,
        currency: str,
        days_ahead: int,
        trip_type: str,
        top_n: int,
        date_from: str | None,
        date_to: str | None,
        return_days: int | None,
        return_date_from: str | None,
        return_date_to: str | None,
    ) -> list[FlightOffer]:
        if trip_type not in {"one_way", "round_trip"}:
            raise ProviderError(f"Unsupported trip_type: {trip_type}")

        max_span = int(os.environ.get("AMADEUS_SEARCH_SPAN_DAYS", "30"))
        if date_from and date_to:
            start_date = date.fromisoformat(date_from)
            end_date = date.fromisoformat(date_to)
            if end_date < start_date:
                raise ProviderError("date_to must be on or after date_from.")
            span = min((end_date - start_date).days + 1, max_span)
        else:
            start_date = date.today() + timedelta(days=1)
            span = min(days_ahead, max_span)

        if trip_type == "round_trip" and return_days is None and not (return_date_from and return_date_to):
            raise ProviderError(
                "return_days or return_date_from/return_date_to is required for round_trip searches."
            )

        if return_date_from and return_date_to:
            return_start = date.fromisoformat(return_date_from)
            return_end = date.fromisoformat(return_date_to)
            if return_end < return_start:
                raise ProviderError("return_date_to must be on or after return_date_from.")
            return_span = min((return_end - return_start).days + 1, max_span)
            return_dates = [return_start + timedelta(days=offset) for offset in range(return_span)]
        else:
            return_dates = []

        offers: list[FlightOffer] = []
        for offset in range(span):
            departure_date = start_date + timedelta(days=offset)
            if trip_type == "round_trip":
                if return_dates:
                    for return_date in return_dates:
                        if return_date < departure_date:
                            continue
                        message = (
                            f"{origin}->{destination}: checking Departing {departure_date.isoformat()} "
                            f"Return {return_date.isoformat()} ({offset + 1}/{span})"
                        )
                        print(message, flush=True)
                        offers.extend(
                            self._search_date(
                                origin=origin,
                                destination=destination,
                                currency=currency,
                                departure_date=departure_date,
                                return_date=return_date,
                            )
                        )
                else:
                    return_date = departure_date + timedelta(days=int(return_days))
                    message = (
                        f"{origin}->{destination}: checking Departing {departure_date.isoformat()} "
                        f"Return {return_date.isoformat()} ({offset + 1}/{span})"
                    )
                    print(message, flush=True)
                    offers.extend(
                        self._search_date(
                            origin=origin,
                            destination=destination,
                            currency=currency,
                            departure_date=departure_date,
                            return_date=return_date,
                        )
                    )
            else:
                message = (
                    f"{origin}->{destination}: checking Departing {departure_date.isoformat()} "
                    f"({offset + 1}/{span})"
                )
                print(message, flush=True)
                offers.extend(
                    self._search_date(
                        origin=origin,
                        destination=destination,
                        currency=currency,
                        departure_date=departure_date,
                        return_date=None,
                    )
                )

        if not offers:
            raise ProviderError("No flights returned by Amadeus API.")

        seen: set[tuple] = set()
        grouped: dict[str, list[FlightOffer]] = {}
        for offer in offers:
            key = (
                offer.price,
                offer.outbound_departure,
                offer.outbound_arrival,
                offer.inbound_departure,
                offer.inbound_arrival,
                offer.carriers,
            )
            if key in seen:
                continue
            seen.add(key)
            departure_key = offer.outbound_departure[:10] if offer.outbound_departure else "unknown"
            grouped.setdefault(departure_key, []).append(offer)

        ordered_keys = sorted(k for k in grouped.keys() if k != "unknown")
        if "unknown" in grouped:
            ordered_keys.append("unknown")

        flattened: list[FlightOffer] = []
        for key in ordered_keys:
            bucket = grouped[key]
            bucket.sort(key=lambda offer: offer.price)
            per_return_seen: set[tuple[str, float]] = set()
            selected: list[FlightOffer] = []
            for offer in bucket:
                return_key = offer.inbound_departure[:10] if offer.inbound_departure else "oneway"
                signature = (return_key, offer.price)
                if signature in per_return_seen:
                    continue
                per_return_seen.add(signature)
                selected.append(offer)
                if len(selected) >= top_n:
                    break
            flattened.extend(selected)

        return flattened
