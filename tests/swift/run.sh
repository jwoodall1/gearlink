#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
scratch=$(mktemp -d /tmp/gearlink-model-tests.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
swiftc -module-cache-path "$scratch/cache" iOS/GearLink/EquipmentModels.swift iOS/GearLink/EquipmentRegistration.swift tests/swift/main.swift -o "$scratch/tests"
"$scratch/tests"
swiftc -module-cache-path "$scratch/cache" iOS/GearLink/EquipmentModels.swift iOS/GearLink/EquipmentRegistration.swift tests/swift/RegistrationTests.swift -o "$scratch/registration-tests"
"$scratch/registration-tests"
swiftc -module-cache-path "$scratch/cache" iOS/GearLink/EquipmentModels.swift iOS/GearLink/EquipmentRegistration.swift iOS/GearLink/NFCWriting.swift tests/swift/NFCWritingTests.swift -o "$scratch/nfc-writing-tests"
"$scratch/nfc-writing-tests"
swiftc -module-cache-path "$scratch/cache" iOS/GearLink/EquipmentModels.swift iOS/GearLink/EquipmentRegistration.swift iOS/GearLink/EquipmentOperations.swift tests/swift/EquipmentOperationsTests.swift -o "$scratch/equipment-tests"
"$scratch/equipment-tests"
