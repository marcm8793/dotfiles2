#!/bin/zsh

# Run this AFTER install.sh to configure your git identity:
#   zsh git_setup.sh

echo "🔧 Setting up Git..."

echo "Type in your first and last name (no accents or special characters):"
read full_name

echo "Type in your email address (the one used for your GitHub account):"
read email

git config --global user.email "$email"
git config --global user.name "$full_name"
git config --global init.defaultBranch main

echo "✅ Git configured for $full_name ($email)"
