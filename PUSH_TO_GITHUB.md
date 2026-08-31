# 📤 تعليمات الـ Push إلى GitHub

## 🎯 الخطوات السريعة

### 1️⃣ افتح Terminal/PowerShell

```bash
# انتقل إلى مجلد المشروع
cd /path/to/camera_parent_fixed
```

### 2️⃣ إعداد git (إذا كان جديد)

```bash
# تحقق من git installation
git --version

# إعداد المعلومات الشخصية
git config --global user.name "Your Name"
git config --global user.email "your.email@gmail.com"
```

### 3️⃣ إنشاء branch جديد للحل

```bash
# أنشئ branch جديد
git checkout -b fix/video-black-screen

# أو إذا كان المشروع بالفعل repo
git pull origin main  # تحديث من الـ remote
```

### 4️⃣ أضف الملفات المعدلة

```bash
# أضف كل الملفات الجديدة والمعدلة
git add .

# أو أضف ملفات محددة
git add lib/utils/webrtc_helper.dart
git add lib/screens/camera_stream_screen.dart
git add lib/screens/camera_viewer_screen.dart
git add CHANGELOG_FIX.md
git add *.md *.txt
```

### 5️⃣ التحقق من التغييرات

```bash
# شوف الملفات المضافة
git status

# شوف الفروقات
git diff --cached
```

### 6️⃣ Commit التغييرات

```bash
# commit مع رسالة وصفية
git commit -m "🎬 Fix: حل مشكلة الفيديو الأسود في Camera Parent

✅ المشاكل المحلولة:
- Helper class الناقص
- الفيديو الأسود مع الصوت يعمل
- معالجة أخطاء getUserMedia
- Texture refresh عند العودة من الخلفية

✨ الإضافات:
- WebRTCHelper class جديد
- Extensions على MediaStream
- Debug logging شامل
- توثيق كامل

📊 التفاصيل:
- 1 ملف جديد (webrtc_helper.dart)
- 2 ملف معدل
- 6 دوال محسّنة
- ~300 سطر كود جديد

🔗 يتعلق بـ: #XXX (رقم issue إذا كان موجود)"
```

### 7️⃣ Push إلى GitHub

```bash
# push الـ branch الجديد
git push -u origin fix/video-black-screen

# أو push إلى branch موجود
git push origin main

# أو push الكل
git push --all
```

### 8️⃣ إنشاء Pull Request (اختياري)

إذا كنت تريد PR:

1. افتح GitHub وانظر للـ notification
2. اضغط "Compare & pull request"
3. أضف وصف PR:

```markdown
## 🎬 الحل الشامل لمشكلة الفيديو الأسود

### 🔴 المشكلة
الفيديو يظهر أسود مع صوت يعمل

### ✅ الحل
إضافة WebRTCHelper class وتحسين معالجة الـ streams

### 📝 التفاصيل
- Helper class جديد في lib/utils/
- فحص video tracks قبل العرض
- معالجة أفضل للأخطاء
- Texture refresh محسّن

### 🧪 الاختبار
- تم اختبار البث الأساسي ✅
- تم اختبار تبديل الكاميرا ✅
- تم اختبار كتم الصوت ✅

### 📚 التوثيق
- CHANGELOG_FIX.md
- QUICK_SUMMARY.md
- STEP_BY_STEP_GUIDE.md
- BUG_REPORT_AND_FIXES.md
```

4. اضغط "Create pull request"

---

## 🔐 مع SSH (اختياري - أفضل)

### إعداد SSH Key (مرة واحدة فقط)

```bash
# إنشاء SSH key
ssh-keygen -t ed25519 -C "your.email@gmail.com"

# أو على Windows
ssh-keygen -t rsa -b 4096 -C "your.email@gmail.com"

# اعرض المفتاح العام
cat ~/.ssh/id_ed25519.pub

# انسخه وأضفه في GitHub Settings → SSH and GPG keys → New SSH key
```

### استخدام SSH

```bash
# غيّر اتجاه الـ remote من HTTPS إلى SSH
git remote set-url origin git@github.com:mas77264447-code/camera_parent.git

# الآن يمكنك push بدون كلمة مرور
git push origin main
```

---

## 🆘 حل المشاكل الشائعة

### المشكلة: "fatal: not a git repository"

```bash
# حل: تأكد أنك في المشروع الصحيح
cd /path/to/camera_parent

# أو ابدأ git من الصفر
git init
git add remote origin https://github.com/mas77264447-code/camera_parent.git
```

### المشكلة: "Permission denied (publickey)"

```bash
# إذا كنت تستخدم SSH، تحقق من المفتاح
ssh -T git@github.com

# إذا فشل، استخدم HTTPS بدلاً منه
git remote set-url origin https://github.com/mas77264447-code/camera_parent.git
```

### المشكلة: "Your branch is behind"

```bash
# تحديث من الـ remote
git pull origin main

# أو rebase إذا كان لديك commits محلية
git pull --rebase origin main
```

### المشكلة: "fatal: The current branch has no upstream"

```bash
# عيّن upstream للـ branch
git push -u origin fix/video-black-screen

# أو يدويًا
git branch --set-upstream-to=origin/main main
```

### المشكلة: "Authentication failed"

```bash
# تحقق من بيانات المستخدم
git config --global user.name
git config --global user.email

# أو استخدم Personal Access Token
# 1. انذهب إلى GitHub Settings → Developer settings → Personal access tokens
# 2. أنشئ token جديد (repo, read:user)
# 3. استخدمه كـ password عند الـ push
```

---

## 📋 قائمة التحقق قبل الـ Push

- [ ] جميع الملفات محفوظة بشكل صحيح
- [ ] لا توجد أخطاء في الكود (flutter analyze)
- [ ] جميع التعديلات تم اختبارها محليًا
- [ ] الـ commit message واضح ووصفي
- [ ] لا توجد ملفات حساسة (مفاتيح، كلمات مرور)
- [ ] تم تحديث README/CHANGELOG
- [ ] تم حذف ملفات مؤقتة (.DS_Store, build/, etc)

---

## 🎯 الأوامر السريعة (من الصفر)

```bash
# 1. انسخ المشروع
git clone https://github.com/mas77264447-code/camera_parent.git
cd camera_parent

# 2. أنشئ branch جديد
git checkout -b fix/video-black-screen

# 3. أضف الملفات
cp -r /path/to/camera_parent_fixed/lib/* lib/
cp -r /path/to/camera_parent_fixed/*.md .
cp -r /path/to/camera_parent_fixed/*.txt .

# 4. أضف للـ git
git add .

# 5. Commit
git commit -m "Fix: حل مشكلة الفيديو الأسود - إضافة WebRTCHelper وتحسينات"

# 6. Push
git push -u origin fix/video-black-screen

# 7. اختياري - merge إلى main
# (عبر GitHub أو محليًا)
git checkout main
git merge fix/video-black-screen
git push origin main
```

---

## 📊 معلومات البيانات

**Repository URL:** 
```
https://github.com/mas77264447-code/camera_parent.git
git@github.com:mas77264447-code/camera_parent.git
```

**Branch الجديد:**
```
fix/video-black-screen
```

**الملفات الرئيسية:**
```
lib/utils/webrtc_helper.dart (جديد)
lib/screens/camera_stream_screen.dart (معدل)
lib/screens/camera_viewer_screen.dart (معدل)
CHANGELOG_FIX.md (جديد)
README.md (معدل)
```

---

## 🚀 نصائح إضافية

### إذا كنت تريد إبقاء سجل الـ commits نظيف

```bash
# Interactive rebase (تحرير commits قبل الـ push)
git rebase -i HEAD~3

# اختر "squash" لدمج commits متعددة
```

### إذا كنت تريد إنشاء Release

```bash
# أنشئ tag
git tag -a v1.0.1-fix -m "إصلاح مشكلة الفيديو الأسود"

# push الـ tag
git push origin v1.0.1-fix
```

### إذا كنت تريد مراقبة التغييرات

```bash
# شوف سجل الـ commits
git log --oneline -10

# شوف الفروقات
git diff main

# شوف من غيّر كل سطر
git blame lib/screens/camera_stream_screen.dart
```

---

## ✅ الخطوات التالية بعد الـ Push

1. **انتظر CI/CD** - إذا كان لديك GitHub Actions
2. **طلب مراجعة** - شارك الـ PR مع الفريق
3. **Merge إلى main** - عند الموافقة
4. **Deploy** - انسخ إلى الإنتاج عند الحاجة
5. **رصد الأخطاء** - تابع Sentry/تطبيقاتك

---

## 💡 نصائح Git المفيدة

```bash
# إرجاع commit آخر
git revert <commit-hash>

# إلغاء آخر commit (محليًا فقط)
git reset --soft HEAD~1

# إظهار الفروقات بين branches
git diff main..fix/video-black-screen

# حذف branch محلي
git branch -d fix/video-black-screen

# حذف branch من الـ remote
git push origin --delete fix/video-black-screen
```

---

**تم إعداد التعليمات بنجاح! 🎉**

الآن أنت جاهز للـ push إلى GitHub. اتبع الخطوات أعلاه وستكون جاهز! 🚀
