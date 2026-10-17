#!/data/data/com.termux/files/usr/bin/bash
# شغّله من جذر الريبو في Termux: bash cleanup_repo.sh
set -e
git rm -r --cached --ignore-unmatch .bash_history .bashrc .gitconfig .lesshst .termux .ssh storage camera_parent camera_parent-fixed-v2 >/dev/null
rm -f android/0 android/ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE android/ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
git rm -f --ignore-unmatch android/0 android/ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE android/ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION >/dev/null
cat >> .gitignore <<'IGN'

# Termux / shell personal files
.bash_history
.bashrc
.gitconfig
.lesshst
.termux/
.ssh/
storage/
key.properties
*.jks
*.keystore
IGN
git add .gitignore
git commit -m "chore: remove Termux personal files, empty submodules and stray files"
echo "تم. الآن: git push"
