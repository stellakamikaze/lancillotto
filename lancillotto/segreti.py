"""Seconda rete contro i segreti: gli stessi pattern del redattore Swift (docs/CONTRATTO.md).

Il registratore redige alla fonte. Questo modulo ripassa ogni testo che esce dalla CLI
(livello 2, note Melchior, descrizioni di Claude): se il redattore Swift ha perso qualcosa,
qui il valore diventa [TIPO]. Non ha HMAC: il segnaposto dice solo il tipo.
"""
from __future__ import annotations

import re

PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)")
JWT = re.compile(r"\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}")
CHIAVE = re.compile(
    r"(?<![A-Za-z0-9])(?:sk-ant-[A-Za-z0-9_\-]{10,}|sk-[A-Za-z0-9_\-]{16,}|ghp_[A-Za-z0-9]{20,}"
    r"|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}"
    r"|xox[abpr]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{30,}|GOCSPX-[A-Za-z0-9_\-]{10,})")
IBAN = re.compile(r"(?<![A-Za-z0-9])(?:[A-Z]{2}\d{2}[A-Z0-9]{11,30}|[A-Z]{2}\d{2}(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,4})?)"
                  r"(?![A-Za-z0-9])", re.IGNORECASE)
_O = "[0-9LMNPQRSTUVlmnpqrstuv]"
CF = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]{6}" + _O + "{2}[ABCDEHLMPRSTabcdehlmprst]" + _O
                + "{2}[A-Za-z]" + _O + "{3}[A-Za-z](?![A-Za-z0-9])")
CARTA = re.compile(r"(?<![\d])(?:\d[ \-]?){12,18}\d(?!\d)")
PASSWORD = re.compile(r"(?i)\b(password|passwd|pwd|passcode)(\s*[:=]\s*)(\S+)")
OTP_RIGA = re.compile(r"(?m)^(\s*)(\d{6,8})(\s*)$")
OTP_DOPO = re.compile(r"(?i)\b(codice|code|otp|verifica|verification)\b([^\d\n]{0,30})(\d{6,8})(?!\d)")
OTP_PRIMA = re.compile(r"(?i)(?<!\d)(\d{6,8})\b([^\d\n]{0,30})\b(codice|code|otp|verifica|verification)\b")

_CF_DISPARI = {
    "0": 1, "1": 0, "2": 5, "3": 7, "4": 9, "5": 13, "6": 15, "7": 17, "8": 19, "9": 21,
    "A": 1, "B": 0, "C": 5, "D": 7, "E": 9, "F": 13, "G": 15, "H": 17, "I": 19, "J": 21,
    "K": 2, "L": 4, "M": 18, "N": 20, "O": 11, "P": 3, "Q": 6, "R": 8, "S": 12, "T": 14,
    "U": 16, "V": 10, "W": 22, "X": 25, "Y": 24, "Z": 23,
}


def luhn(cifre: str) -> bool:
    totale = 0
    for i, c in enumerate(reversed(cifre)):
        n = int(c)
        if i % 2 == 1:
            n *= 2
            if n > 9:
                n -= 9
        totale += n
    return totale % 10 == 0


def iban_valido(s: str) -> bool:
    s = s.replace(" ", "").upper()
    if len(s) < 15 or len(s) > 34 or not s[:2].isalpha() or not s[2:4].isdigit():
        return False
    riordinato = s[4:] + s[:4]
    numero = "".join(str(int(c, 36)) for c in riordinato)
    return int(numero) % 97 == 1


def cf_valido(s: str) -> bool:
    s = s.upper()
    if len(s) != 16:
        return False
    totale = 0
    for i, c in enumerate(s[:15]):
        if i % 2 == 0:
            totale += _CF_DISPARI[c]
        else:
            totale += int(c) if c.isdigit() else ord(c) - ord("A")
    return chr(ord("A") + totale % 26) == s[15]


def redigi(testo: str):
    """(testo redatto, tipi trovati). Ogni segreto diventa [TIPO]."""
    if not testo:
        return testo, []
    trovati = []

    def sost(tipo):
        def f(m):
            trovati.append(tipo)
            return "[%s]" % tipo
        return f

    t = PEM.sub(sost("PEM"), testo)
    t = JWT.sub(sost("JWT"), t)
    t = CHIAVE.sub(sost("CHIAVE"), t)

    def iban(m):
        if iban_valido(m.group(0)):
            trovati.append("IBAN")
            return "[IBAN]"
        return m.group(0)
    t = IBAN.sub(iban, t)

    def cf(m):
        if cf_valido(m.group(0)):
            trovati.append("CF")
            return "[CF]"
        return m.group(0)
    t = CF.sub(cf, t)

    def carta(m):
        cifre = re.sub(r"[ \-]", "", m.group(0))
        if 13 <= len(cifre) <= 19 and luhn(cifre):
            trovati.append("CARTA")
            return "[CARTA]"
        return m.group(0)
    t = CARTA.sub(carta, t)

    def pwd(m):
        trovati.append("PASSWORD")
        return m.group(1) + m.group(2) + "[PASSWORD]"
    t = PASSWORD.sub(pwd, t)

    def otp_riga(m):
        trovati.append("OTP")
        return m.group(1) + "[OTP]" + m.group(3)
    t = OTP_RIGA.sub(otp_riga, t)

    def otp_dopo(m):
        trovati.append("OTP")
        return m.group(1) + m.group(2) + "[OTP]"
    t = OTP_DOPO.sub(otp_dopo, t)

    def otp_prima(m):
        trovati.append("OTP")
        return "[OTP]" + m.group(2) + m.group(3)
    t = OTP_PRIMA.sub(otp_prima, t)
    return t, trovati


def trova(testo: str) -> list:
    """I tipi di segreto presenti nel testo, senza doppioni. Mai il valore."""
    _t, tipi = redigi(testo)
    return list(dict.fromkeys(tipi))
