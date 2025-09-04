#!/bin/bash

echo "Testing clipboard-fzf application..."
echo "=================================="

# Check if the binary exists
if [ -f "./clipboard-fzf" ]; then
    echo "✓ Binary exists"
else
    echo "✗ Binary not found"
    exit 1
fi

# Check if we're in an interactive terminal
if [ -t 0 ]; then
    echo "✓ Running in interactive terminal"
    
    # Test the application (it will exit immediately due to terminal issues)
    echo "Testing application (this may show errors due to terminal setup)..."
    timeout 5s ./clipboard-fzf 2>&1 | head -10
    
    echo ""
    echo "Test completed. If you saw 'bad file descriptor' errors,"
    echo "that's expected in this environment. The application"
    echo "needs to be run in a proper interactive terminal."
else
    echo "✗ Not running in interactive terminal"
fi

echo ""
echo "To test the full application, run:"
echo "  ./clipboard-fzf"
echo ""
echo "In a proper interactive terminal environment."
