#!/bin/zsh

echo "⚠️  Time to reboot... Continue? (y/N)"
read -r confirm

if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
  echo "🔄 Rebooting now..."
  sudo shutdown -r now
else
  echo "❌ Cancelled."
fi
