import logging
import os
import time
from zoneinfo import ZoneInfo

from .service import generate_cycle
from .storage import initialize


def main():
    logging.basicConfig(level=logging.INFO)
    path = os.environ.get("PAIR_DB", "instance/pair.sqlite3")
    zone = os.environ.get("PAIR_TIMEZONE", "UTC")
    ZoneInfo(zone)
    initialize(path)
    logging.info("Matching worker started; timezone=%s", zone)
    while True:
        try:
            if generate_cycle(path, zone):
                logging.info("Published the current weekly cycle")
        except Exception:
            logging.exception("Matching cycle failed; retrying")
        time.sleep(60)


if __name__ == "__main__":
    main()
