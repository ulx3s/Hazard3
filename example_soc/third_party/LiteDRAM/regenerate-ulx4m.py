#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File:        regenerate-ulx4m.py
# Path:        example_soc/third_party/LiteDRAM/regenerate-ulx4m.py
#
# Project:     Hazard3-Doom
# Purpose:     Generate and validate ULX4M-LD LiteDRAM CPU variants.
#
# Copyright (c) 2026 gojimmypi
#
# Licensed under the Apache License, Version 2.0.
#
# SPDX-License-Identifier: Apache-2.0
#
# This software is provided under the terms of the applicable license.
# See LICENSES/Apache-2.0.txt for the complete license terms.
# See LICENSING.md for project licensing policy and scope.
# -----------------------------------------------------------------------------

import argparse
import importlib.metadata
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, Optional

import yaml

CORE_NAME = "litedram_ulx4m_cpu"
HOST_PACKAGES = {
    "litex": "2024.12",
    "litedram": "2024.12",
    "migen": "0.9.2",
}
SOFTWARE_PACKAGES = {
    "pythondata-cpu-serv": "1.2.0.post146",
    "pythondata-cpu-vexriscv": "1.0.1.post407",
    "pythondata-software-picolibc": "1.7.9.post181",
    "pythondata-software-compiler-rt": "0.0.post6206",
}
CPU_PROFILES = {
    "serv": {
        "cpu": "serv",
        "package": "pythondata-cpu-serv",
        "generated_dir": "generated-serv",
    },
    "vexrisc": {
        "cpu": "vexriscv",
        "package": "pythondata-cpu-vexriscv",
        "generated_dir": "generated-vexrisc",
    },
}
RAM_CLASSES = {
    "MT41K512M16HA": "MT41K512M16",
    "AS4C256M16D3": "AS4C256M16D3A",
}


def package_versions(path: Optional[Path] = None) -> Dict[str, str]:
    if path is None:
        return {name: importlib.metadata.version(name) for name in HOST_PACKAGES}
    return {
        distribution.metadata["Name"].lower(): distribution.version
        for distribution in importlib.metadata.distributions(path=[str(path)])
    }


def verify_versions(expected: Dict[str, str], actual: Dict[str, str]) -> None:
    failed = False
    for package, wanted in expected.items():
        found = actual.get(package.lower())
        if found is None:
            print(f"Missing Python package: {package}=={wanted}", file=sys.stderr)
            failed = True
            continue
        print(f"{package}={found}")
        if found != wanted:
            print(
                f"ERROR: expected {package}=={wanted}, found {found}",
                file=sys.stderr,
            )
            failed = True
    if failed:
        raise SystemExit(1)


def read_config(path: Path) -> Dict[str, object]:
    with path.open("r", encoding="utf-8") as source:
        config = yaml.safe_load(source)
    if not isinstance(config, dict):
        raise SystemExit(f"LiteDRAM profile is not a YAML mapping: {path}")
    return config


def find_one(root: Path, filename: str) -> Path:
    matches = list(root.rglob(filename))
    if len(matches) != 1:
        raise SystemExit(
            f"Expected exactly one generated {filename} below {root}; "
            f"found {len(matches)}"
        )
    return matches[0]


def append_serv_rtl(output: Path, pydata_dir: Path) -> None:
    sys.path.insert(0, str(pydata_dir))
    import pythondata_cpu_serv

    package_dir = Path(pythondata_cpu_serv.__file__).resolve().parent
    roots = []
    for value in (getattr(pythondata_cpu_serv, "data_location", None), package_dir):
        if value is not None:
            root = Path(value).resolve()
            roots.extend((root, root / "verilog"))

    rtl_dir = None
    for root in roots:
        candidate = root / "rtl"
        if (candidate / "serv_rf_top.v").is_file():
            rtl_dir = candidate
            break
    if rtl_dir is None:
        raise SystemExit(
            f"Could not locate SERV RTL below pythondata_cpu_serv package {package_dir}"
        )

    sources = sorted(rtl_dir.glob("serv_*.v"))
    required = {
        "serv_rf_top.v",
        "serv_top.v",
        "serv_state.v",
        "serv_decode.v",
        "serv_alu.v",
    }
    missing = sorted(required - {path.name for path in sources})
    if missing:
        raise SystemExit("Missing required SERV RTL: " + ", ".join(missing))

    with output.open("a", encoding="utf-8", newline="\n") as destination:
        destination.write("\n")
        for source in sources:
            text = source.read_text(encoding="utf-8")
            destination.write(text)
            if not text.endswith("\n"):
                destination.write("\n")
    print(f"Embedded {len(sources)} SERV RTL source files from {rtl_dir}")


def append_vexrisc_rtl(output: Path, pydata_dir: Path) -> None:
    sys.path.insert(0, str(pydata_dir))
    from pythondata_cpu_vexriscv import data_file

    source = Path(data_file("VexRiscv_Min.v"))
    text = source.read_text(encoding="utf-8")
    if re.search(r"^\s*module\s+VexRiscv(?:\s|#|\(|$)", text, re.MULTILINE) is None:
        raise SystemExit(f"{source} does not define module VexRiscv")

    with output.open("a", encoding="utf-8", newline="\n") as destination:
        destination.write("\n")
        destination.write(text)
        if not text.endswith("\n"):
            destination.write("\n")
    print(f"Embedded VexRiscv minimal RTL from {source}")


def postprocess_verilog(
    path: Path,
    generated_rel: str,
    ram_part: str,
    config: Dict[str, object],
    cpu_package: str,
) -> None:
    cpu = str(config["cpu"])
    cpu_variant = str(config["cpu_variant"])
    memory_class = str(config["sdram_module"])
    text = path.read_text(encoding="utf-8")

    for suffix in ("rom.init", "sram.init"):
        name = f"{CORE_NAME}_{suffix}"
        replacement = f'$readmemh("{generated_rel}/{name}"'
        pattern = rf'\$readmemh\("[^"]*{re.escape(name)}"'
        text, count = re.subn(pattern, replacement, text)
        if count != 1:
            raise SystemExit(
                f"Expected exactly one $readmemh reference for {name}; found {count}"
            )

    header = (
        "// ULX4M-LD LiteDRAM generated core.\n"
        "// LiteDRAM 2024.12, LiteX 2024.12, Migen 0.9.2\n"
        f"// DDR3: {ram_part}; LiteDRAM class: {memory_class}\n"
        f"// CPU: {cpu} ({cpu_variant}); "
        f"{cpu_package} {SOFTWARE_PACKAGES[cpu_package]}\n"
        "// FPGA: LFE5UM-85F-8BG381C; input 25 MHz; "
        "LiteDRAM sys 60 MHz; DDR3-240.\n"
        "// Generated by regenerate-ulx4m.sh. Do not edit this file manually.\n"
        "// ----------------------------------------------------------------------\n"
    )
    if not text.startswith("// ULX4M-LD LiteDRAM generated core."):
        text = header + text
    path.write_text(text, encoding="utf-8", newline="\n")


def validate_and_embed_cpu(generated_verilog: Path, cpu: str, pydata_dir: Path) -> None:
    text = generated_verilog.read_text(encoding="utf-8")
    serv_definition = re.compile(r"^\s*module\s+serv_rf_top(?:\s|#|\(|$)", re.MULTILINE)
    vexrisc_definition = re.compile(r"^\s*module\s+VexRiscv(?:\s|#|\(|$)", re.MULTILINE)

    if cpu == "serv":
        if "serv_rf_top" not in text:
            raise SystemExit("Generated core does not instantiate SERV serv_rf_top")
        if vexrisc_definition.search(text):
            raise SystemExit("Generated SERV core unexpectedly contains VexRiscv")
        if serv_definition.search(text) is None:
            append_serv_rtl(generated_verilog, pydata_dir)
        text = generated_verilog.read_text(encoding="utf-8")
        if serv_definition.search(text) is None:
            raise SystemExit("Combined generated core does not define serv_rf_top")
    elif cpu == "vexriscv":
        if "VexRiscv VexRiscv" not in text:
            raise SystemExit("Generated core does not instantiate VexRiscv")
        if serv_definition.search(text):
            raise SystemExit("Generated VexRiscv core unexpectedly contains SERV")
        if vexrisc_definition.search(text) is None:
            append_vexrisc_rtl(generated_verilog, pydata_dir)
        text = generated_verilog.read_text(encoding="utf-8")
        if vexrisc_definition.search(text) is None:
            raise SystemExit("Combined generated core does not define VexRiscv")
    else:
        raise SystemExit(f"Unsupported CPU in LiteDRAM profile: {cpu}")


def write_versions(
    output: Path,
    profile_source: Path,
    ram_part: str,
    config: Dict[str, object],
    cpu_package: str,
) -> None:
    values = [
        "LiteDRAM=2024.12",
        "LiteX=2024.12",
        "Migen=0.9.2",
        f"profile_source={profile_source.as_posix()}",
        f"ram_part={ram_part}",
        f"memory_class={config['sdram_module']}",
        f"CPU={config['cpu']}",
        f"CPU_variant={config['cpu_variant']}",
        f"{cpu_package}={SOFTWARE_PACKAGES[cpu_package]}",
        f"FPGA={config['device']}",
        f"input_clk_freq={config['input_clk_freq']}",
        f"sys_clk_freq={config['sys_clk_freq']}",
        f"init_clk_freq={config['init_clk_freq']}",
        f"sdram_phy={config['sdram_phy']}",
        f"memory_modules={config['sdram_module_nb']}",
        f"memory_ranks={config['sdram_rank_nb']}",
        f"user_port={config['user_ports']['wb']['type']}",
        f"user_port_data_width={config['user_ports']['wb']['data_width']}",
    ]
    output.write_text("\n".join(values) + "\n", encoding="utf-8", newline="\n")


def generate_profile(
    script_dir: Path,
    temp_dir: Path,
    pydata_dir: Path,
    ram_part: str,
    profile_name: str,
) -> None:
    profile = CPU_PROFILES[profile_name]
    config_source = script_dir / "configs" / ram_part / f"{profile_name}.yml"
    config = read_config(config_source)
    if config.get("cpu") != profile["cpu"]:
        raise SystemExit(
            f"{config_source}: expected cpu {profile['cpu']}, found {config.get('cpu')}"
        )
    expected_memory_class = RAM_CLASSES[ram_part]
    if config.get("sdram_module") != expected_memory_class:
        raise SystemExit(
            f"{config_source}: expected sdram_module {expected_memory_class}, "
            f"found {config.get('sdram_module')}"
        )

    output_dir = script_dir / str(profile["generated_dir"])
    generated_rel = f"../third_party/LiteDRAM/{profile['generated_dir']}"
    profile_temp = temp_dir / profile_name
    saved_config = profile_temp / config_source.name
    build_dir = profile_temp / "build"
    if not build_dir.is_dir():
        build_dir.mkdir(parents=True)
        shutil.copyfile(config_source, saved_config)
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(pydata_dir) + (
            f":{environment['PYTHONPATH']}" if environment.get("PYTHONPATH") else ""
        )
        subprocess.run(
            [
                sys.executable,
                "-m",
                "litedram.gen",
                str(config_source),
                "--name",
                CORE_NAME,
                "--output-dir",
                str(build_dir),
            ],
            check=True,
            env=environment,
        )
    elif (
        not saved_config.is_file()
        or saved_config.read_bytes() != config_source.read_bytes()
    ):
        raise SystemExit(
            f"Saved {profile_name} build does not match {config_source}; "
            "use a different HAZARD3_ULX4M_REUSE_TMP directory"
        )

    generated_verilog = find_one(build_dir, f"{CORE_NAME}.v")
    generated_rom = find_one(build_dir, f"{CORE_NAME}_rom.init")
    sram_matches = list(build_dir.rglob(f"{CORE_NAME}_sram.init"))
    if len(sram_matches) > 1:
        raise SystemExit(
            f"Expected at most one generated {CORE_NAME}_sram.init; "
            f"found {len(sram_matches)}"
        )
    generated_sram = (
        sram_matches[0]
        if sram_matches
        else temp_dir / profile_name / f"{CORE_NAME}_sram.init"
    )
    if not generated_sram.exists():
        generated_sram.touch()

    cpu_package = str(profile["package"])
    postprocess_verilog(
        generated_verilog,
        generated_rel,
        ram_part,
        config,
        cpu_package,
    )
    validate_and_embed_cpu(generated_verilog, str(config["cpu"]), pydata_dir)

    generated_text = generated_verilog.read_text(encoding="utf-8")
    for suffix in ("rom.init", "sram.init"):
        expected_path = f"{generated_rel}/{CORE_NAME}_{suffix}"
        if expected_path not in generated_text:
            raise SystemExit(
                f"Generated core path was not normalized to {expected_path}"
            )

    output_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(config_source, output_dir / f"{CORE_NAME}.yml")
    shutil.copyfile(generated_verilog, output_dir / f"{CORE_NAME}.v")
    shutil.copyfile(generated_rom, output_dir / f"{CORE_NAME}_rom.init")
    shutil.copyfile(generated_sram, output_dir / f"{CORE_NAME}_sram.init")
    write_versions(
        output_dir / "LITEDRAM_VERSIONS.txt",
        config_source.relative_to(script_dir),
        ram_part,
        config,
        cpu_package,
    )

    print(f"Regenerated {profile_name} for {ram_part}: {output_dir}")


def verify_picolibc_source(pydata_dir: Path) -> None:
    sys.path.insert(0, str(pydata_dir))
    import pythondata_software_picolibc

    meson_build = Path(pythondata_software_picolibc.data_location) / "meson.build"
    text = meson_build.read_text(encoding="utf-8")
    match = re.search(r"^[ \t]*version\s*:\s*['\"]([^'\"]+)['\"]", text, re.MULTILINE)
    if match is None:
        raise SystemExit(
            f"Could not determine Picolibc source version from {meson_build}"
        )
    print(f"picolibc-source={match.group(1)}")
    if match.group(1) != "1.7.9":
        raise SystemExit(
            f"Expected Picolibc source 1.7.9 for LiteX 2024.12; found {match.group(1)}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Regenerate ULX4M-LD LiteDRAM cores for a DDR3 part."
    )
    parser.add_argument("ram_part")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    config_root = script_dir / "configs"
    profile_dir = config_root / args.ram_part
    if args.ram_part not in RAM_CLASSES or not profile_dir.is_dir():
        supported = sorted(RAM_CLASSES)
        parser.error(
            f"unsupported RAM part number {args.ram_part}; "
            f"choose one of: {', '.join(supported)}"
        )
    for profile_name in CPU_PROFILES:
        config_source = profile_dir / f"{profile_name}.yml"
        if not config_source.is_file():
            raise SystemExit(f"Missing LiteDRAM profile: {config_source}")

    try:
        verify_versions(HOST_PACKAGES, package_versions())
    except importlib.metadata.PackageNotFoundError as error:
        raise SystemExit(f"Missing Python package: {error.name}") from error

    reuse_temp = os.environ.get("HAZARD3_ULX4M_REUSE_TMP")
    created_temp = reuse_temp is None
    temp_dir = (
        Path(reuse_temp).resolve()
        if reuse_temp is not None
        else Path(tempfile.mkdtemp(prefix="hazard3-litedram-"))
    )
    pydata_dir = temp_dir / "pydata"

    try:
        if created_temp:
            packages = [
                f"{package}=={version}"
                for package, version in SOFTWARE_PACKAGES.items()
            ]
            subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "pip",
                    "install",
                    "--disable-pip-version-check",
                    "--no-cache-dir",
                    "--no-deps",
                    "--target",
                    str(pydata_dir),
                    *packages,
                ],
                check=True,
            )
        elif not pydata_dir.is_dir():
            raise SystemExit(f"Saved Python-data directory not found: {pydata_dir}")

        verify_versions(SOFTWARE_PACKAGES, package_versions(pydata_dir))
        verify_picolibc_source(pydata_dir)
        for profile_name in CPU_PROFILES:
            generate_profile(
                script_dir,
                temp_dir,
                pydata_dir,
                args.ram_part,
                profile_name,
            )
    except BaseException:
        print(
            f"Generation failed; preserving temporary directory: {temp_dir}",
            file=sys.stderr,
        )
        raise
    else:
        if created_temp:
            shutil.rmtree(temp_dir)


if __name__ == "__main__":
    main()
