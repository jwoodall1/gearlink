#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
scratch=$(mktemp -d /tmp/gearlink-integration-tests.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
swiftc -module-cache-path "$scratch/cache" iOS/GearLink/EquipmentModels.swift iOS/GearLink/EquipmentRegistration.swift iOS/GearLink/NFCWriting.swift iOS/GearLink/EquipmentOperations.swift tests/swift/DatabaseIntegrationTests.swift -o "$scratch/tests"
"$scratch/tests" "$@"
