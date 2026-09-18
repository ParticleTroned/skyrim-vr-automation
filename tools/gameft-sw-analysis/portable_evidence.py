"""Replace machine paths in publication copies without changing originals."""
import hashlib
import json
import re


class PortableEvidence:
    """Normalize known roots and retain unknown replacements in a local map."""

    def __init__(self, roots):
        self.roots = sorted(roots.items(), key=lambda item: len(item[0]), reverse=True)
        self.local_mapping = {}

    def text(self, value):
        if value.lstrip().startswith(("{", "[")):
            try:
                nested = json.loads(value)
            except (ValueError, RecursionError):
                pass
            else:
                return json.dumps(self.value(nested), ensure_ascii=True, separators=(",", ":"))
        for root, label in self.roots:
            variants = {root.replace("\\", "/"), root.replace("/", "\\")}
            variants |= {path.replace("\\", "\\\\") for path in variants}
            for path in sorted(variants, key=len, reverse=True):
                value = re.sub(re.escape(path), lambda _: label, value, flags=re.IGNORECASE)

        def replace(match):
            original = match.group(0)
            label = "${LOCAL_PATH_" + hashlib.sha256(original.encode()).hexdigest()[:12] + "}"
            self.local_mapping[label] = original
            return label

        # Unknown machine roots remain resolvable through an unversioned map.
        return re.sub(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]+[^"\'<>\r\n`|]*', replace, value)

    def value(self, value):
        if isinstance(value, dict):
            result = {}
            for key, child in value.items():
                portable_key = self.text(key)
                if portable_key in result:
                    raise ValueError("Path normalization collided with another object key")
                result[portable_key] = self.value(child)
            return result
        if isinstance(value, list):
            return [self.value(child) for child in value]
        return self.text(value) if isinstance(value, str) else value
