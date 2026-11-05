"""Validate bundle metadata and publish a freshly assembled app with rollback."""
from pathlib import Path
import os
import plistlib
import sys
import uuid
import xml.etree.ElementTree as ET


def read_plist(data):
    if not data.startswith(b'bplist'):
        for dictionary in ET.fromstring(data).iter('dict'):
            keys = [node.text for node in dictionary if node.tag == 'key']
            if len(keys) != len(set(keys)):
                raise ValueError('Duplicate plist dictionary key')
    return plistlib.loads(data)


def publish_bundle(staged, destination):
    staged, destination = Path(staged), Path(destination)
    backup = staged.parent / ('previous-' + str(uuid.uuid4()) + '.app')
    had_previous = destination.exists()
    if destination.is_symlink():
        raise ValueError('Refusing to replace a symbolic-link app destination.')
    if had_previous:
        os.replace(destination, backup)
    try:
        os.replace(staged, destination)
    except BaseException:
        if had_previous:
            os.replace(backup, destination)
        raise
    # The caller owns the disposable staging directory, including the old app.


if __name__ == '__main__':
    publish_bundle(*sys.argv[1:])
