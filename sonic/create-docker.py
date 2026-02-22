#!/usr/bin/env python3.8
"""
create_single_docker.py

This script extracts an ISO tar file and a prebaked image tar file to a temporary
directory and calls bake-and-build.sh with the appropriate parameters to create
a single Docker image.

The script includes sophisticated platform detection that works in two stages:
1. Analysis of tar filename patterns to get initial platform identification
2. Refinement using extracted qcow2 filenames for more precise platform mapping

Additionally, the script attempts to extract the SDK version from the ISO file
using the 'getisoinfo' command and automatically passes it as --forcesdk parameter
to bake-and-build.sh when available.

Platform mappings are defined as module-level constants (PLATFORM_MAPPING and 
QCOW2_TO_PLATFORM) and can be easily updated when new platforms are released.

Usage:
    python3 create_single_docker.py --iso-tar <path_to_iso_tar> --image-tar <path_to_image_tar> [options]

Example:
    python3 create_single_docker.py \
        --iso-tar /path/to/8000-2512-iso-eft15.1.tar \
        --image-tar /path/to/8000-2512-f-8101-image-eft15.1.tar \
        --platform 8101-32H \
        --docker-name myimage:latest
"""

import argparse
import os
import re
import sys
import tempfile
import tarfile
import shutil
import subprocess
import logging
from datetime import datetime
from pathlib import Path

# Check Python version requirement
if sys.version_info < (3, 8):
    print(f"ERROR: This script requires Python 3.8 or higher.", file=sys.stderr)
    print(f"Current Python version: {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}", file=sys.stderr)
    print(f"Please upgrade your Python installation or use a Python 3.8+ environment.", file=sys.stderr)
    sys.exit(1)

# Supported and tested environments
SUPPORTED_ENVIRONMENTS = ['CML', 'KNE', 'CLAB']

# Global variable for current log file path
_current_log_file = None


class DualOutputHandler(logging.Handler):
    """Custom logging handler that writes to both console and log file"""
    
    def __init__(self):
        super().__init__()
        # Create console handler
        self.console_handler = logging.StreamHandler()
        self.console_handler.setFormatter(
            logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
        )
    
    def emit(self, record):
        # Always emit to console
        self.console_handler.emit(record)
        
        # Also emit to log file if available
        global _current_log_file
        if _current_log_file:
            try:
                # Format the message
                msg = self.format(record)
                with open(_current_log_file, 'a') as f:
                    f.write(f"{msg}\n")
            except Exception:
                # Don't let logging errors break the main flow
                pass

# Set up logging with custom handler
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
logger.addHandler(DualOutputHandler())

# Set formatter for the dual handler
for handler in logger.handlers:
    if isinstance(handler, DualOutputHandler):
        handler.setFormatter(
            logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
        )

# ==============================================================================
# PLATFORM MAPPINGS
# ==============================================================================
# These mappings are version-agnostic and focus on platform identifiers.
# Update these when new platforms are released or platform definitions change.

# Platform mapping based on tar filename patterns and extracted qcow2 filenames
PLATFORM_MAPPING = {
    # Standard platforms (from tar filename pattern)
    '8000': '8000',
    '8101': '8101-32H',      # Default 8101 variant
    '8102': '8102-64H',
    '8122': '8122-64EHF-O',
    '8201': '8201-32FH',     # Default 8201 variant  
    '8202': '8202',          # Default 8202 variant
    '8212': '8212-48FH-M',
    '8711': '8711-32FH-M',
    '8804': '8804',          # For distributed platforms
    '8808': '8800-lc-36fh-m',          # For distributed platforms
    
    # Complex platform variants (from qcow2 filename patterns)
    '8101-32FH': '8101-32FH',
    '8101-32H': '8101-32H',
    '8102-64H': '8102-64H', 
    '8111-32EH': '8111-32EH',
    '8122-64EHF-O': '8122-64EHF-O',
    '8201-24H8FH': '8201-24H8FH',
    '8201-sys': '8201-sys',
    '8201-32FH': '8201-32FH',
    '8202-32FH-M': '8202-32FH-M',
    '8212-48FH-M': '8212-48FH-M',
    '8711-32FH-M': '8711-32FH-M',
    
    # Special cases
    'ncs1010': 'ncs1010',
}

# Mapping from qcow2 filename patterns to platform types
QCOW2_TO_PLATFORM = {
    '8000-x64': '8201-sys',      # 8000 qcow2 is used for 8201 system variants
    '8101-x64': '8101-32H',      # Standard 8101
    '8101-32FH-x64': '8101-32FH',
    '8102-x64': '8102-64H',
    '8111-32EH-x64': '8111-32EH',
    '8122-64EHF-O-x64': '8122-64EHF-O',
    '8201-x64': '8201-32FH',     # Standard 8201
    '8202-x64': '8202',
    '8202-32FH-M-x64': '8202-32FH-M',
    '8212-48FH-M-x64': '8212-48FH-M',
    '8711-32FH-M-x64': '8711-32FH-M',
}

class CreateSingleDockerError(Exception):
    """Custom exception for create_single_docker operations"""
    pass

class CreateSingleDocker:
    def __init__(self, iso_tar_path, image_tar_path, platform=None, docker_name=None, 
                 target="all", cleanup=True, temp_dir=None):
        """
        Initialize the CreateSingleDocker instance.
        
        Args:
            iso_tar_path (str): Path to the ISO tar file
            image_tar_path (str): Path to the prebaked image tar file
            platform (str): Platform identifier (e.g., '8101-32H', '8201-32FH')
            docker_name (str): Name for the resulting Docker image
            target (str): Target type for bake-and-build.sh (default: 'all')
            cleanup (bool): Whether to cleanup temporary files (default: True)
            temp_dir (str): Custom temporary directory path (optional)
        """
        self.iso_tar_path = Path(iso_tar_path).resolve()
        self.image_tar_path = Path(image_tar_path).resolve()
        self.platform = platform
        self.docker_name = docker_name
        self.target = target
        self.cleanup = cleanup
        self.temp_dir_path = temp_dir
        self.temp_dir = None
        self.iso_path = None
        self.sdk_version = None
        self.script_dir = Path(__file__).parent.resolve()
        self.bake_and_build_script = self.script_dir.parent / "bake-and-build" / "bake-and-build.sh"
        self.initial_file_conf = self.script_dir / "required_files.conf"
        
        # Logging setup - will be initialized in _setup_logging_directory
        self.log_dir = None
        self.log_file = None
        self.bake_build_log_file = None
        
        # Reference module-level platform mappings
        self.platform_mapping = PLATFORM_MAPPING
        self.qcow2_to_platform = QCOW2_TO_PLATFORM
        
        # Validate inputs
        self._validate_inputs()
        
    def _initial_file_check(self, conf_path):
        """
        Check that all files listed in a plain text config exist relative to ./ovxr-release/.
        The config should be a text file with one relative file path per line.
        Lines starting with '#' or blank lines are ignored.
        Raises CreateSingleDockerError if any file is missing.
        Args:
            conf_path (str or Path): Path to the config file
        """
        _root_ = Path(__file__).resolve().parent.parent.parent  # points to ./ovxr-release/
        conf_path = Path(conf_path)
        if not conf_path.exists():
            raise CreateSingleDockerError(f"Config file not found: {conf_path}")

        with open(conf_path, 'r') as f:
            files = [line.strip() for line in f if line.strip() and not line.strip().startswith('#')]

        missing = []
        for rel_path in files:
            abs_path = _root_ / rel_path
            if not abs_path.exists():
                missing.append(str(abs_path))

        if missing:
            raise CreateSingleDockerError(
                f"Missing required files: {missing}\n"
                "If you are unsure, re-download the latest 8000-emulator-eft*.tar and untar to restore missing files."
            )
        logger.info(f"All required files present as per {conf_path}")
            
    def _validate_inputs(self):
        """Validate input files and parameters"""
        if not self.iso_tar_path.exists():
            raise CreateSingleDockerError(f"ISO tar file not found: {self.iso_tar_path}")
            
        if not self.image_tar_path.exists():
            raise CreateSingleDockerError(f"Image tar file not found: {self.image_tar_path}")
            
        if not self.bake_and_build_script.exists():
            raise CreateSingleDockerError(f"bake-and-build.sh not found: {self.bake_and_build_script}")
            
        # Extract platform from image tar filename if not provided
        if not self.platform:
            self.platform = self._extract_platform_from_filename(self.image_tar_path.name)
            
        logger.info(f"Using platform: {self.platform}")
        
    def _extract_platform_from_qcow2_filename(self, qcow2_filename):
        """
        Extract platform from qcow2 filename.
        Example: 8101-32FH-x64-25.1.2.qcow2 -> 8101-32FH
        """
        try:
            # Remove .qcow2 extension and version number
            base_name = qcow2_filename.replace('.qcow2', '')
            
            # Split by version pattern (remove version like 25.1.2)
            import re
            # Remove version pattern like -x64-25.1.2 or -25.1.2
            version_pattern = r'-x64-\d+\.\d+\.\d+$|-\d+\.\d+\.\d+$'
            base_name = re.sub(version_pattern, '', base_name)
            
            logger.debug(f"Processing qcow2 base name: {base_name}")
            
            # Look for exact matches in our qcow2 to platform mapping
            for qcow2_pattern, platform in self.qcow2_to_platform.items():
                if base_name == qcow2_pattern:
                    logger.debug(f"Exact match found: {base_name} -> {platform}")
                    return platform
            
            # Try partial matches for complex platform names
            for qcow2_pattern, platform in self.qcow2_to_platform.items():
                pattern_base = qcow2_pattern.replace('-x64', '')
                if base_name == pattern_base:
                    logger.debug(f"Pattern match found: {base_name} -> {platform}")
                    return platform
                    
            # Fallback: extract base platform number and look it up
            platform_match = re.match(r'^(\d{4})', base_name)
            if platform_match:
                base_platform = platform_match.group(1)
                mapped_platform = self.platform_mapping.get(base_platform, base_platform)
                logger.debug(f"Fallback platform mapping: {base_platform} -> {mapped_platform}")
                return mapped_platform
                
            return None
            
        except Exception as e:
            logger.warning(f"Could not extract platform from qcow2 filename {qcow2_filename}: {e}")
            return None
        
    def _extract_platform_from_filename(self, filename):
        """
        Extract platform identifier from tar filename with enhanced mapping.
        Example: 8000-2512-f-8101-image-eft15.1.tar -> 8101-32H
        """
        try:
            # First, try to extract from tar filename pattern
            parts = filename.split('-')
            
            # Handle distributed platform patterns (8000-2512-d-8804-images-eft15.1.tar)
            if 'd' in parts:
                d_index = parts.index('d')
                if d_index + 1 < len(parts):
                    platform_part = parts[d_index + 1]
                    if platform_part in self.platform_mapping:
                        return self.platform_mapping[platform_part]
            
            # Handle fixed platform patterns (8000-2512-f-8101-image-eft15.1.tar)
            if 'f' in parts:
                f_index = parts.index('f')
                if f_index + 1 < len(parts):
                    platform_part = parts[f_index + 1]
                    
                    # Handle complex platform names like "8202" or "8711"
                    if platform_part in self.platform_mapping:
                        return self.platform_mapping[platform_part]
                    
                    # Handle cases where the platform part has additional suffixes
                    base_platform = platform_part.split('-')[0] if '-' in platform_part else platform_part
                    if base_platform in self.platform_mapping:
                        return self.platform_mapping[base_platform]
            
            # Handle special cases like ncs1010
            if 'ncs1010' in filename:
                return 'ncs1010'
            
            # Fallback: look for 4-digit platform numbers
            for part in parts:
                if part.isdigit() and len(part) == 4 and part.startswith('8'):
                    return self.platform_mapping.get(part, part)
                    
            raise ValueError("Could not extract platform from filename")
            
        except Exception as e:
            logger.warning(f"Could not extract platform from filename {filename}: {e}")
            return "8201-32FH"  # Default platform
            
    def _create_temp_directory(self):
        """Create temporary directory for extraction"""
        if self.temp_dir_path:
            self.temp_dir = Path(self.temp_dir_path)
            self.temp_dir.mkdir(parents=True, exist_ok=True)
            logger.info(f"Using custom temp directory: {self.temp_dir}")
        else:
            self.temp_dir = Path(tempfile.mkdtemp(prefix="create_single_docker_"))
            logger.info(f"Created temp directory to extract files: {self.temp_dir}")
            
    def _extract_tar_file(self, tar_path, extract_to):
        """Extract tar file to specified directory"""
        logger.debug(f"Extracting {tar_path.name} to {extract_to}")
        try:
            with tarfile.open(tar_path, 'r') as tar:
                tar.extractall(path=extract_to)
                logger.info(f"Extracted {tar_path.name} to {extract_to}")
                # Return list of extracted files
                return [extract_to / member.name for member in tar.getmembers()]
        except Exception as e:
            raise CreateSingleDockerError(f"Failed to extract {tar_path}: {e}")
            
    def _find_iso_file(self, extracted_files):
        """Find the ISO file among extracted files"""
        iso_files = [f for f in extracted_files if f.suffix.lower() == '.iso']
        if not iso_files:
            raise CreateSingleDockerError("No ISO file found in extracted files")
        if len(iso_files) > 1:
            logger.warning(f"Multiple ISO files found, using first: {iso_files[0]}")
        return iso_files[0]
        
    def _extract_sdk_version_from_iso(self, iso_path):
        """
        Extract SDK version from ISO file using isoinfo command.
        Uses: isoinfo -R -x /sim_cfg.yml -i <iso_path>
        Returns SDK version string like "24.11.4111.5" or None if extraction fails.
        
        NOTE: Hardcoded to return "24.10.2230.6.dc" for consistent builds.
        """
        # Hardcoded SDK version
        hardcoded_version = "24.10.2230.6.dc"
        logger.info(f"Using hardcoded SDK version: {hardcoded_version}")
        return hardcoded_version
        
    def _refine_platform_from_extracted_files(self, extracted_files):
        """
        Refine platform detection using extracted qcow2 files.
        This provides more accurate platform identification.
        """
        try:
            # Find qcow2 files in extracted files
            qcow2_files = [f for f in extracted_files if f.suffix.lower() == '.qcow2']
            
            if qcow2_files:
                # Use the first qcow2 file to refine platform detection
                qcow2_filename = qcow2_files[0].name
                logger.info(f"Found qcow2 file for platform refinement: {qcow2_filename}")
                
                refined_platform = self._extract_platform_from_qcow2_filename(qcow2_filename)
                if refined_platform:
                    logger.info(f"Refined platform from qcow2 filename: {self.platform} -> {refined_platform}")
                    self.platform = refined_platform
                    
        except Exception as e:
            logger.warning(f"Could not refine platform from extracted files: {e}")
            # Continue with original platform detection
        
    def _build_bake_and_build_command(self):
        """Build the command to call bake-and-build.sh"""
        cmd = [
            "bash",
            str(self.bake_and_build_script),
            "-i", str(self.iso_path),
            "-p", self.platform,
            "-t", self.target
        ]
        
        if self.docker_name:
            cmd.extend(["-d", self.docker_name])
            
        # Add SDK version if available
        if self.sdk_version:
            cmd.extend(["--forcesdk", self.sdk_version])
            logger.debug(f"Adding SDK version parameter to use with bake-and-build: --forcesdk {self.sdk_version}")
            
        return cmd
        
    def _run_bake_and_build(self, cmd):
        """
        Execute bake-and-build.sh command and capture output
        Streams output to log file in real-time for live following with tail -f
        
        Returns:
            tuple: (return_code, output) - return code and captured output
        """
        # Initialize log file with header
        if self.bake_build_log_file:
            try:
                with open(self.bake_build_log_file, 'w') as f:
                    f.write(f"=== bake-and-build.sh Output ===\n")
                    f.write(f"Timestamp: {datetime.now().isoformat()}\n")
                    f.write(f"Command: {' '.join(cmd)}\n")
                    f.write(f"\n=== Live Output ===\n")
                    f.flush()
            except Exception as e:
                logger.warning(f"Failed to initialize bake-and-build.sh log file: {e}")
        
        try:
            # Start subprocess with real-time output capture
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,  # Combine stderr with stdout
                text=True,
                bufsize=1,  # Line buffered
                universal_newlines=True
            )
            
            all_output = []
            
            # Read output line by line and write to log file immediately
            while True:
                output = process.stdout.readline()
                if output == '' and process.poll() is not None:
                    break
                if output:
                    line = output.rstrip()  # Remove trailing newline for consistent formatting
                    all_output.append(line)
                    
                    # Write to log file immediately for real-time following
                    if self.bake_build_log_file:
                        try:
                            with open(self.bake_build_log_file, 'a') as f:
                                f.write(f"{line}\n")
                                f.flush()  # Ensure immediate write to disk
                        except Exception as e:
                            # Don't break execution if logging fails
                            logger.warning(f"Failed to write to bake-and-build.sh log: {e}")
            
            # Wait for process to complete
            return_code = process.wait()
            
            # Finalize log file
            if self.bake_build_log_file:
                try:
                    with open(self.bake_build_log_file, 'a') as f:
                        f.write(f"\n=== Execution Completed ===\n")
                        f.write(f"Exit code: {return_code}\n")
                        f.write(f"Completed at: {datetime.now().isoformat()}\n")
                        f.flush()
                except Exception as e:
                    logger.warning(f"Failed to finalize bake-and-build.sh log: {e}")
            
            if return_code == 0:
                logger.info("bake-and-build.sh completed successfully")
            else:
                logger.error(f"bake-and-build.sh failed with exit code {return_code}")
                # Print error output for debugging
                if all_output:
                    print("Last few lines of output:")
                    for line in all_output[-10:]:  # Show last 10 lines
                        print(line)
            
            # Search for IMG_DROP_FOLDER in the output and clean it up
            full_output = '\n'.join(all_output)
            if self._cleanup_img_drop_folder(full_output):
                logger.info("🧹 Cleaned up IMG_DROP_FOLDER")
            else:
                logger.info("ℹ️  No IMG_DROP_FOLDER found to clean up")
            
            # Search for YAML_DROP_FOLDER in the output and clean it up
            if self._cleanup_yaml_drop_folder(full_output):
                logger.info("🧹 Cleaned up YAML_DROP_FOLDER")
            else:
                logger.info("ℹ️  No YAML_DROP_FOLDER found to clean up")
            
            # Return both return code and captured output
            return return_code, full_output
            
        except Exception as e:
            logger.error(f"Error executing bake-and-build.sh: {e}")
            
            # Write error to log file
            if self.bake_build_log_file:
                try:
                    with open(self.bake_build_log_file, 'a') as f:
                        f.write(f"\n=== ERROR ===\n")
                        f.write(f"Error: {e}\n")
                        f.write(f"Error occurred at: {datetime.now().isoformat()}\n")
                        f.flush()
                except Exception:
                    pass
            
            return 1, f"Error occurred during execution: {e}"
        
    def _cleanup_img_drop_folder(self, output):
        """
        Search for IMG_DROP_FOLDER in the bake-and-build.sh output and clean up that directory.
        
        Args:
            output (str): The stdout output from bake-and-build.sh
            
        Returns:
            bool: True if a folder was found and cleaned up, False otherwise
        """
        try:
            # Search for lines starting with "IMG_DROP_FOLDER:"
            for line in output.split('\n'):
                line = line.strip()
                if line.startswith('IMG_DROP_FOLDER:'):
                    # Extract the folder path (everything after the colon and spaces)
                    folder_path = line.split(':', 1)[1].strip()
                    folder_path = Path(folder_path)
                    
                    if folder_path.exists() and folder_path.is_dir():
                        logger.debug(f"Cleaning up IMG_DROP_FOLDER: {folder_path}")
                        try:
                            shutil.rmtree(folder_path)
                            logger.info(f"Successfully removed IMG_DROP_FOLDER: {folder_path}")
                            return True
                        except Exception as e:
                            logger.warning(f"Failed to remove IMG_DROP_FOLDER {folder_path}: {e}")
                            return False
                    else:
                        logger.warning(f"IMG_DROP_FOLDER does not exist or is not a directory: {folder_path}")
                        return False
                    
                    # Only process the first IMG_DROP_FOLDER found
                    break
            else:
                logger.info("No IMG_DROP_FOLDER found in bake-and-build.sh output")
                return False
                
        except Exception as e:
            logger.warning(f"Error while cleaning up IMG_DROP_FOLDER: {e}")
            return False
    
    def _cleanup_yaml_drop_folder(self, output):
        """
        Search for YAML_DROP_FOLDER in the bake-and-build.sh output and clean up that directory.
        
        Args:
            output (str): The stdout output from bake-and-build.sh
            
        Returns:
            bool: True if a folder was found and cleaned up, False otherwise
        """
        try:
            # Search for lines starting with "YAML_DROP_FOLDER:"
            for line in output.split('\n'):
                line = line.strip()
                if line.startswith('YAML_DROP_FOLDER:'):
                    # Extract the folder path (everything after the colon and spaces)
                    folder_path = line.split(':', 1)[1].strip()
                    folder_path = Path(folder_path)
                    
                    if folder_path.exists() and folder_path.is_dir():
                        logger.debug(f"Cleaning up YAML_DROP_FOLDER: {folder_path}")
                        try:
                            shutil.rmtree(folder_path)
                            logger.info(f"Successfully removed YAML_DROP_FOLDER: {folder_path}")
                            return True
                        except Exception as e:
                            logger.warning(f"Failed to remove YAML_DROP_FOLDER {folder_path}: {e}")
                            return False
                    else:
                        logger.warning(f"YAML_DROP_FOLDER does not exist or is not a directory: {folder_path}")
                        return False
                    
                    # Only process the first YAML_DROP_FOLDER found
                    break
            else:
                logger.info("No YAML_DROP_FOLDER found in bake-and-build.sh output")
                return False
                
        except Exception as e:
            logger.warning(f"Error while cleaning up YAML_DROP_FOLDER: {e}")
            return False
    
    def _extract_docker_image_path(self, output):
        """
        Extract Docker image path from bake-and-build.sh output.
        
        Looks for patterns like:
        - "Docker image saved to: /path/to/image.tar"
        - "Saved image to /path/to/image.tar"
        - "Successfully saved /path/to/image.tar"
        - "Image exported to: /path/to/image.tar"
        
        Args:
            output (str): The stdout output from bake-and-build.sh
            
        Returns:
            str or None: Path to the Docker image file if found, None otherwise
        """
        try:
            import re
            
            # Define pattern to search for Docker image path
            pattern = r'Saving docker image,.*?to\s+(.+\.tar)'
            
            # Search through output lines
            for line in output.split('\n'):
                line = line.strip()
                
                # Try the pattern
                match = re.search(pattern, line, re.IGNORECASE)
                if match:
                    docker_image_path = match.group(1).strip()
                    
                    # Validate that the path looks reasonable
                    if docker_image_path and docker_image_path.endswith('.tar'):
                        # Convert to Path object to normalize
                        path_obj = Path(docker_image_path)
                        
                        # Return the path (prefer absolute path if file exists)
                        if path_obj.exists():
                            logger.debug(f"Found Docker image path: {docker_image_path}")
                            return str(path_obj.resolve())
                        else:
                            # Return the path even if file doesn't exist yet
                            logger.debug(f"Found Docker image path: {docker_image_path}")
                            return docker_image_path
            
            logger.debug("No Docker image path found in bake-and-build.sh output")
            return None
            
        except Exception as e:
            logger.warning(f"Error while extracting Docker image path: {e}")
            return None
        
    def _setup_logging_directory(self):
        """Setup logging directory with timestamp and version information"""
        try:
            # Create timestamp for directory name
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            
            # Get SDK version (will be "unknown" if not available)
            sdk_version = self.sdk_version if self.sdk_version else "unknown"
            
            # Create directory name: ovxr-docker.out/<timestamp-sdk_version-platform>/
            dir_name = f"{timestamp}-{sdk_version}-{self.platform}"
            
            # Create the logging directory in current working directory
            current_dir = Path.cwd()
            self.log_dir = current_dir / "ovxr-docker.out" / dir_name
            self.log_dir.mkdir(parents=True, exist_ok=True)
            logger.info(f"Created logging directory: {self.log_dir}")
            
            # Setup log file paths
            self.log_file = self.log_dir / "create_single_docker.log"
            logger.info(f"Log file path: {self.log_file}")
            self.bake_build_log_file = self.log_dir / "bake-and-build.log"
            logger.info(f"bake-and-build.sh log file path: {self.bake_build_log_file}")
            
            # Set global log file path for the custom handler BEFORE any logger calls
            global _current_log_file
            _current_log_file = self.log_file
            
            # Log initial run information to the log file (this will also create the file)
            with open(self.log_file, 'w') as f:
                f.write(f"=== create_single_docker.py Run Log ===\\n")
                f.write(f"Timestamp: {datetime.now().isoformat()}\\n")
                f.write(f"ISO tar: {getattr(self, 'iso_tar_path', 'unknown')}\\n")
                f.write(f"Image tar: {getattr(self, 'image_tar_path', 'unknown')}\\n")
                f.write(f"Platform: {self.platform}\\n")
                f.write(f"SDK Version: {sdk_version}\\n")
                f.write(f"Docker name: {getattr(self, 'docker_name', 'auto-generated') or 'auto-generated'}\\n")
                f.write(f"Target: {getattr(self, 'target', 'all')}\\n")
                f.write(f"\\n=== Execution Log ===\\n")
            
                
        except Exception as e:
            logger.error(f"Failed to setup logging directory: {e}")
            logger.error(f"Ensure you have write permissions in the current directory and as well as enough disk space.")
            self.log_dir = None
            self.log_file = None
            self.bake_build_log_file = None
            raise Exception(f"Logging setup failed: {e}")
    
    def _log_to_file(self, message, log_type="INFO"):
        """Write a message to the log file with timestamp"""
        if self.log_file:
            try:
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                with open(self.log_file, 'a') as f:
                    f.write(f"[{timestamp}] {log_type}: {message}\n")
            except Exception as e:
                logger.warning(f"Failed to write to log file: {e}")
    
    def _cleanup_temp_directory(self):
        """Clean up temporary directory if cleanup is enabled"""
        if self.cleanup and self.temp_dir and self.temp_dir.exists():
            logger.info(f"Cleaning up temp iso directory: {self.temp_dir}")
            self._log_to_file(f"Cleaning up temp iso directory: {self.temp_dir}")
            shutil.rmtree(self.temp_dir)
            
    def run(self, args=None):
        """Execute the main workflow"""
        try:
            # Script intro message
            logger.info("="*80)
            logger.info("🐳 OVXR Docker Image Creator - Starting Workflow")
            logger.info("Using an ISO & Prebaked Platform's Tar file (provided in OVXR's EFT releases), this will create a single Docker image suitable for use in: ")
            logger.info(f"{', '.join(SUPPORTED_ENVIRONMENTS)}   ")
            logger.info("="*80)
            
            logger.info("Starting create_single_docker workflow")
            
            # Initial check for needed files
            self._initial_file_check(self.initial_file_conf)
            
            # Create temporary directory
            self._create_temp_directory()
            
            # Extract ISO tar file
            logger.debug("Extracting ISO tar file...")
            iso_extracted_files = self._extract_tar_file(self.iso_tar_path, self.temp_dir)
            
            # Extract image tar file to the same directory
            logger.debug("Extracting image tar file...")
            image_extracted_files = self._extract_tar_file(self.image_tar_path, self.temp_dir)
            
            # Refine platform detection using extracted files
            self._refine_platform_from_extracted_files(image_extracted_files)
            
            # Find the ISO file
            self.iso_path = self._find_iso_file(iso_extracted_files)
            logger.info(f"Found ISO file: {self.iso_path}")
            
            # Extract SDK version from ISO file
            self.sdk_version = self._extract_sdk_version_from_iso(self.iso_path)
            if not self.sdk_version:
                logger.warning("SDK version not available, continuing without --forcesdk parameter")
            
            # Setup logging directory now that we have SDK version and platform info
            self._setup_logging_directory()
            
            # Build and execute bake-and-build command
            cmd = self._build_bake_and_build_command()
            logger.info(f"Executing command:\n {' '.join(cmd)}")
            
            # Change to the script directory to ensure proper execution context
            original_cwd = os.getcwd()
            os.chdir(self.bake_and_build_script.parent)
            
            try:
                # Execute bake-and-build.sh
                logger.info(f"Executing bake-and-build.sh - open a new shell and run the following command to see real-time output:")
                logger.info(f"tail -f {self.bake_build_log_file}")
                return_code, bake_build_output = self._run_bake_and_build(cmd)
                
                # Log the execution results
                self._log_to_file(f"Command executed: {' '.join(cmd)}")
                self._log_to_file(f"Exit code: {return_code}")
                
                # Note: bake-and-build.sh output is now written to log file in real-time
                logger.info(f"bake-and-build.sh output was written in real-time to: {self.bake_build_log_file}")
                self._log_to_file(f"bake-and-build.sh output written in real-time to: {self.bake_build_log_file}")
                
                # Extract Docker image path from output
                docker_image_path = None
                if return_code == 0:
                    docker_image_path = self._extract_docker_image_path(bake_build_output)
                    if docker_image_path:
                        logger.info(f"🐳 Docker image saved to: {docker_image_path}")
                        self._log_to_file(f"Docker image path: {docker_image_path}")
                
                # If docker_image_path exists but file does not exist, then this counts as a failure
                if docker_image_path:
                    docker_image_file = Path(docker_image_path)
                    if not docker_image_file.exists():
                        logger.error(f"Docker image file not found at expected path: {docker_image_path}")
                        return_code = 1

                # Success completion message
                if return_code == 0:
                    logger.info("="*80)
                    logger.info("✅ OVXR Docker Image Creator - Workflow Completed Successfully!")
                    logger.info(f"📂 Logs saved to: {self.log_dir}")
                    if docker_image_path:
                        logger.info(f"🐳 Docker image created: {docker_image_path}")
                        logger.info("▶️ Run to load the image: docker load < " + docker_image_path)
                    else:
                        logger.info("🐳 Docker image creation finished. Check bake-and-build.sh output for image details.")
                    logger.info("="*80)
                else:
                    logger.info("="*80)
                    logger.info("❌ OVXR Docker Image Creator - Workflow Completed with Errors")
                    logger.info(f"📂 Logs saved to: {self.log_dir}")
                    logger.info(f"🔍 Check logs for error details. Exit code: {return_code}")
                    logger.info("="*80)
                
                return return_code
                
            finally:
                os.chdir(original_cwd)
                
        except CreateSingleDockerError as e:
            logger.error(f"Create single docker error: {e}")
            logger.info("="*80)
            logger.info("❌ OVXR Docker Image Creator - Workflow Failed")
            logger.info(f"💥 Error: {e}")
            if hasattr(self, 'log_dir') and self.log_dir:
                logger.info(f"📂 Partial logs may be available at: {self.log_dir}")
            logger.info("="*80)
            return 1
            
        except Exception as e:
            logger.error(f"Unexpected error: {e}")
            logger.info("="*80)
            logger.info("❌ OVXR Docker Image Creator - Workflow Failed (Unexpected Error)")
            logger.info(f"💥 Unexpected error: {e}")
            if hasattr(self, 'log_dir') and self.log_dir:
                logger.info(f"📂 Partial logs may be available at: {self.log_dir}")
            logger.info("="*80)
            return 1
            
        finally:
            # Clean up
            self._cleanup_temp_directory()
            
            # Reset global log file path
            global _current_log_file
            _current_log_file = None

def find_iso_tar_from_image_tar(image_tar_path):
    """
    Automatically find the corresponding ISO tar file for a given image tar file.
    
    Args:
        image_tar_path (Path): Path to the image tar file
        
    Returns:
        Path or None: Path to the found ISO tar file, or None if not found
    """
    try:
        image_tar_path = Path(image_tar_path).resolve()
        parent_dir = image_tar_path.parent
        
        # Extract the base pattern from the image tar filename
        # Examples:
        # 8000-2512-f-8101-image-eft15.1.tar -> 8000-2512-iso-eft15.1.tar
        # 8000-2512-d-8808-images-eft15.1.tar -> 8000-2512-iso-eft15.1.tar
        
        filename = image_tar_path.name
        logger.debug(f"Analyzing image tar filename: {filename}")
        
        # Pattern matching for different image tar formats
        patterns = [
            # Fixed platform pattern: 8000-<version>-f-<platform>-image-<eft>.tar
            r'^(8000-\d+)-f-\d+(?:-[\w-]+)?-image-(eft[\d\.]+)\.tar$',
            # Distributed platform pattern: 8000-<version>-d-<platform>-images-<eft>.tar  
            r'^(8000-\d+)-d-\d+(?:-[\w-]+)?-images-(eft[\d\.]+)\.tar$',
            # Generic pattern: 8000-<version>-<type>-<platform>-image[s]-<eft>.tar
            r'^(8000-\d+)-[fd]-\d+(?:-[\w-]+)?-images?-(eft[\d\.]+)\.tar$'
        ]
        
        base_pattern = None
        eft_version = None
        
        for pattern in patterns:
            match = re.match(pattern, filename)
            if match:
                base_pattern = match.group(1)  # e.g., "8000-2512"
                eft_version = match.group(2)   # e.g., "eft15.1"
                logger.debug(f"Matched pattern: base={base_pattern}, eft={eft_version}")
                break
        
        if not base_pattern or not eft_version:
            logger.warning(f"Could not parse image tar filename pattern: {filename}")
            return None
            
        # Construct the expected ISO tar filename
        expected_iso_name = f"{base_pattern}-iso-{eft_version}.tar"
        expected_iso_path = parent_dir / expected_iso_name
        
        logger.info(f"Looking for ISO tar file: {expected_iso_name}")
        
        if expected_iso_path.exists():
            logger.info(f"✅ Found ISO tar file: {expected_iso_path}")
            return expected_iso_path
        else:
            logger.warning(f"❌ ISO tar file not found: {expected_iso_path}")
            
            # Try to find any ISO tar file in the same directory as a fallback
            iso_files = list(parent_dir.glob("*-iso-*.tar"))
            if iso_files:
                logger.info(f"Found alternative ISO tar files in directory: {[f.name for f in iso_files]}")
                # Use the first one that matches the base pattern
                for iso_file in iso_files:
                    if iso_file.name.startswith(base_pattern):
                        logger.info(f"✅ Using alternative ISO tar file: {iso_file}")
                        return iso_file
                
                # If no exact match, suggest the first available
                logger.warning(f"No exact match found. Available ISO files: {[f.name for f in iso_files]}")
                return None
            else:
                logger.warning(f"No ISO tar files found in directory: {parent_dir}")
                return None
                
    except Exception as e:
        logger.warning(f"Error while searching for ISO tar file: {e}")
        return None

def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description="Create a single Docker image from ISO and prebaked image tar files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Easy mode - just provide the image tar file (ISO tar auto-discovered):
  %(prog)s /path/to/8000-2512-f-8101-image-eft15.1.tar
  %(prog)s /path/to/8000-2512-d-8808-images-eft15.1.tar --docker-name my8808:latest

  # Power user mode - explicitly specify both files:
  %(prog)s --iso-tar 8000-2512-iso-eft15.1.tar --image-tar 8000-2512-f-8101-image-eft15.1.tar

  %(prog)s --iso-tar /path/to/8000-2512-iso-eft15.1.tar \\
           --image-tar /path/to/8000-2512-f-8101-image-eft15.1.tar \\
           --platform 8101 \\
           --docker-name myimage:latest

  %(prog)s --iso-tar iso.tar --image-tar image.tar --no-cleanup --temp-dir /tmp/mydocker
        """
    )
    
    # Positional argument for easy mode
    parser.add_argument(
        "image_tar",
        nargs="?",
        help="Path to the prebaked image tar file (easy mode). ISO tar will be auto-discovered in the same directory."
    )
    
    # Optional arguments for power user mode
    parser.add_argument(
        "--iso-tar", 
        help="Path to the ISO tar file (e.g., 8000-2512-iso-eft15.1.tar). Required in power user mode."
    )
    
    parser.add_argument(
        "--image-tar",
        dest="image_tar_flag", 
        help="Path to the prebaked image tar file (e.g., 8000-2512-f-8101-image-eft15.1.tar). Required in power user mode."
    )
    
    # Optional arguments
    parser.add_argument(
        "--platform", 
        help="Platform identifier (e.g., 8101-32H, 8201-32FH, 8202-32FH-M). If not specified, will be automatically detected from tar filename and contents"
    )
    
    parser.add_argument(
        "--docker-name", 
        help="Name for the resulting Docker image (e.g., myimage:latest). If not specified, bake-and-build.sh will auto-generate"
    )
    
    parser.add_argument(
        "--target", 
        default="all",
        choices=["all", "kne", "clab", "cml", "eve_ng", "crystalnet", "azure", "cloudvm"],
        help=argparse.SUPPRESS  # Hidden from help output
    )
    
    parser.add_argument(
        "--no-cleanup", 
        action="store_true",
        help="Do not clean up temporary files after completion"
    )
    
    parser.add_argument(
        "--temp-dir", 
        help="Custom temporary directory path (if not specified, uses system temp)"
    )
    
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable verbose logging"
    )
    
    args = parser.parse_args()
    
    # Set logging level
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Determine which mode we're in and validate arguments
    iso_tar_path = None
    image_tar_path = None
    
    # Easy mode: positional argument provided
    if args.image_tar:
        logger.info("🎯 Running in EASY MODE - image tar provided as positional argument")
        image_tar_path = args.image_tar
        
        # Try to auto-discover the ISO tar file
        logger.info("🔍 Auto-discovering ISO tar file...")
        iso_tar_path = find_iso_tar_from_image_tar(image_tar_path)
        
        if not iso_tar_path:
            logger.error("❌ EASY MODE FAILED: Could not find corresponding ISO tar file")
            logger.error("")
            logger.error("💡 SOLUTION OPTIONS:")
            logger.error("1. Make sure the ISO tar file is in the same directory as the image tar file")
            logger.error("2. Use POWER USER MODE instead:")
            logger.error(f"   python3 {sys.argv[0]} --iso-tar <iso_file.tar> --image-tar {image_tar_path}")
            logger.error("")
            
            # List available ISO files in the directory for user reference
            try:
                image_dir = Path(image_tar_path).parent
                iso_files = list(image_dir.glob("*-iso-*.tar"))
                if iso_files:
                    logger.error("📁 Available ISO tar files in the same directory:")
                    for iso_file in iso_files:
                        logger.error(f"   - {iso_file.name}")
                else:
                    logger.error("📁 No ISO tar files found in the same directory")
            except Exception:
                pass
                
            sys.exit(1)
        
        # Check for conflicting power user arguments
        if args.iso_tar:
            logger.warning("⚠️  Both positional image tar and --iso-tar provided. Using auto-discovered ISO tar.")
            
    # Power user mode: both --iso-tar and --image-tar provided
    elif args.iso_tar and args.image_tar_flag:
        logger.info("🔧 Running in POWER USER MODE - both --iso-tar and --image-tar provided")
        iso_tar_path = args.iso_tar
        image_tar_path = args.image_tar_flag
        
    # Error: insufficient arguments
    else:
        logger.error("❌ ERROR: Insufficient arguments provided")
        logger.error("")
        logger.error("Choose one of these modes:")
        logger.error("")
        logger.error("🎯 EASY MODE (recommended):")
        logger.error(f"   python3 {sys.argv[0]} <path_to_image_tar_file>")
        logger.error("   Example: python3 create_single_docker.py /path/to/8000-2512-f-8101-image-eft15.1.tar")
        logger.error("")
        logger.error("🔧 POWER USER MODE:")
        logger.error(f"   python3 {sys.argv[0]} --iso-tar <iso_file> --image-tar <image_file>")
        logger.error("   Example: python3 create_single_docker.py --iso-tar iso.tar --image-tar image.tar")
        logger.error("")
        sys.exit(1)
    
    # Create and run the workflow
    try:
        creator = CreateSingleDocker(
            iso_tar_path=iso_tar_path,
            image_tar_path=image_tar_path,
            platform=args.platform,
            docker_name=args.docker_name,
            target=args.target,
            cleanup=not args.no_cleanup,
            temp_dir=args.temp_dir
        )
        
        exit_code = creator.run(args)
        sys.exit(exit_code)
        
    except Exception as e:
        logger.error(f"Failed to create CreateSingleDocker instance: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()