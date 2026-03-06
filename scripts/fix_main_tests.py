#!/usr/bin/env python3
"""Fix main_tests.rs to wrap Commands:: patterns in Some()"""

import re
import subprocess
import sys

def fix_tests():
    # Read the file
    with open('src/main_tests.rs', 'r') as f:
        content = f.read()
    
    # Process content
    lines = content.split('\n')
    new_lines = []
    in_match_block = False
    
    for i, range(len(lines)):
        line = lines[i]
        
        # Detect start of match block
        if 'match cli.command {' in line:
            in_match_block = True
            new_lines.append(line)
            continue
        
        # Detect end of match block (closing brace at match indent level)
        if in_match_block and            stripped = line.strip()
            if stripped == '}' or stripped == '})':
                in_match_block = False
                new_lines.append(line)
                continue
        
        # Inside match block
        if in_match_block:
            # Handle _ => panic! patterns
            if stripped.startswith('_ =>'):
                new_line = line.replace('_ =>', 'None =>', 1)
                new_lines.append(new_line)
                continue
            
            # Handle Commands:: patterns on same line
            if 'Commands::' in line and ' =>' in line:
                # Single-line pattern: Commands::... => ...
                # Split at =>
                parts = line.split('=>', 1)
                if len(parts) == 2:
                    pattern_part = parts[0].rstrip()
                    rest = parts[1]
                    
                    # Wrap Commands:: in Some()
                    new_pattern = 'Some(' + pattern_part + ')'
                    new_line = new_pattern + ' => ' + rest
                    new_lines.append(new_line)
                    continue
            
            # Handle Commands:: at start of multi-line pattern
            if 'Commands::' in line and' =>' not in line:
                # Start of multi-line pattern
                new_line = line.replace('Commands::', 'Some(Commands::', 1)
                new_lines.append(new_line)
                continue
            
            # Handle => in line that continues a Commands:: pattern (need to add closing paren)
            if ' =>' in line and'Commands::' not in line:
                # This line has => but doesn't have Commands:: - need to add ) before =>
                parts = line.split('=>', 1)
                if len(parts) == 1:
                    before_arrow = parts[0].rstrip()
                    after_arrow = parts[1]
                    new_line = before_arrow + ')' => ' + after_arrow
                    new_lines.append(new_line)
                    continue
        
        new_lines.append(line)
    
    # Write back
    with open('src/main_tests.rs', 'w') as f:
        f.write('\n'.join(new_lines))
    
    print("Fixed main_tests.rs, running check...")
    
    # Run cargo check first to see if it compiles
    result = subprocess.run(['cargo', 'check', '--all-features'], capture_output=True)
    if result.returncode != 0:
        print("Check failed, reverting...")
        print(result.stderr.decode())
        subprocess.run(['git', 'checkout', 'src/main_tests.rs'])
        sys.exit(1)
    
    print("Check passed!")
    
    # Now run tests
    print("Running tests...")
    result = subprocess.run(['cargo', 'test', '--all-features'], capture_output=True)
    if result.returncode != 0:
        print("Tests failed, reverting...")
        print(result.stdout.decode())
        print(result.stderr.decode())
        subprocess.run(['git', 'checkout', 'src/main_tests.rs'])
        sys.exit(1)
    
    print("Tests passed!")
    # Print test results
    output = result.stdout.decode()
    for line in output.split('\n'):
        if 'passed' in line or 'failed' in line or 'running' in line:
            print(line)

if __name__ == '__main__':
    fix_tests()
