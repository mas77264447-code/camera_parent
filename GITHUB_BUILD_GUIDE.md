# 🚀 دليل البناء والرفع على GitHub

**خطوة بخطوة لبناء APK في GitHub Actions ورفعه تلقائياً**

---

## 📋 الخطوة 1: تحضير المستودع المحلي

```bash
# انتقل إلى مجلد المشروع
cd ~/storage/downloads/camera_parent

# إذا لم تكن أنشأت git بعد:
git init

# أضف كل الملفات
git add .

# أول commit
git commit -m "Initial commit - camera_parent app"
```

---

## 🌐 الخطوة 2: إنشاء Repository على GitHub

### 2.1: اذهب إلى GitHub.com
```
https://github.com/new
```

### 2.2: ملء البيانات
- **Repository name:** camera_parent
- **Description:** Camera Parent App - Flutter
- **Public/Private:** Public (لكي يرى الجميع الـ Actions)
- **Initialize:** NO (لا تختر أي شيء)
- اضغط "Create repository"

### 2.3: الـ URL ستكون شيء مثل:
```
https://github.com/username/camera_parent.git
```

---

## 🔗 الخطوة 3: ربط المستودع المحلي بـ GitHub

```bash
# أضف remote (هذا هو الـ GitHub repo)
git remote add origin https://github.com/YOUR_USERNAME/camera_parent.git

# تحقق من أنه موجود
git remote -v

# يجب أن ترى:
# origin    https://github.com/YOUR_USERNAME/camera_parent.git (fetch)
# origin    https://github.com/YOUR_USERNAME/camera_parent.git (push)
```

---

## 📤 الخطوة 4: رفع الملفات إلى GitHub

```bash
# تعيين الـ branch إلى main
git branch -M main

# رفع الملفات
git push -u origin main

# قد يطلب منك اسم المستخدم والـ token
# استخدم:
# Username: YOUR_USERNAME
# Password: personal access token (راجع أدناه)
```

### إذا لم تملك Personal Access Token:

1. اذهب: https://github.com/settings/tokens
2. اضغط "Generate new token (classic)"
3. أعطه اسم: `github_actions`
4. اختر الصلاحيات:
   - ✅ repo (كل شيء)
   - ✅ workflow
5. اضغط "Generate token"
6. **انسخ التوكن** (لن تراه مرة أخرى!)
7. استخدمه كـ password في `git push`

---

## ✅ الخطوة 5: تحقق من الرفع

```bash
# في GitHub، افتح repo الخاص بك:
https://github.com/YOUR_USERNAME/camera_parent

# يجب أن ترى:
# - جميع الملفات
# - مجلد .github/workflows/build_and_release.yml ✅
```

---

## 🔨 الخطوة 6: تشغيل البناء الأول

### الطريقة 1: تلقائياً (عند كل push)
```bash
# أي تعديل وpush سيشغّل البناء
git add .
git commit -m "update: something"
git push
```

### الطريقة 2: يدويّاً
1. اذهب إلى: `https://github.com/YOUR_USERNAME/camera_parent`
2. اضغط على tab **"Actions"**
3. اختر **"Build and Release APK"**
4. اضغط **"Run workflow"**
5. اختر **"main"** branch
6. اضغط **"Run workflow"**

---

## 👀 الخطوة 7: مراقبة البناء

1. اذهب إلى **Actions** tab
2. اضغط على آخر build
3. اضغط على **"build"** job
4. شاهد الخطوات:
   - ✅ Checkout code
   - ✅ Setup Java
   - ✅ Setup Flutter
   - ✅ Get dependencies
   - ✅ Analyze code
   - ✅ Build Parent APK
   - ✅ Build Child APK
   - ✅ Upload artifacts

---

## 📥 الخطوة 8: تحميل APK المبني

### بعد انتهاء البناء مباشرة:

1. اذهب إلى **Actions** tab
2. اضغط على آخر build الناجح
3. ستجد **Artifacts** في الأسفل:
   - 📦 app-parent-release
   - 📦 app-child-release
4. اضغط على أي منهما لتحميله

---

## 🏷️ الخطوة 9: إنشاء Release رسمي

### إذا أردت إصدار رسمي:

```bash
# أنشئ tag
git tag v1.0.1-fixed

# اضغطه إلى GitHub
git push origin v1.0.1-fixed

# سيشغّل البناء تلقائياً
# وسينشئ Release مع APKs كـ attachments
```

### أو من GitHub مباشرة:
1. اذهب إلى **Releases** tab
2. اضغط **"Create a new release"**
3. اختر tag: **v1.0.1-fixed**
4. العنوان: **Release v1.0.1-fixed**
5. الوصف: 
   ```
   ## Camera Parent App - v1.0.1-fixed
   
   ### تحسينات:
   - ✅ إصلاح StreamControllers memory leak
   - ✅ إزالة ! operator
   - ✅ إضافة error boundaries
   - ✅ Redis error handling محسّن
   
   ### الملفات:
   - app-parent-release.apk (Parent version)
   - app-child-release.apk (Child version)
   ```
6. اضغط **"Publish release"**

---

## 📊 مراقبة البناء

### Dashboard المفيدة:

```
🟢 Actions: https://github.com/USERNAME/camera_parent/actions
🏷️ Releases: https://github.com/USERNAME/camera_parent/releases
📦 Artifacts: في كل build
```

---

## 🆘 استكشاف الأخطاء

### إذا فشل البناء:

1. **اقرأ الـ Error** في Actions tab
2. **ابحث عن:**
   - `Error: Couldn't resolve package` → تحديث pubspec.yaml
   - `Gradle build failed` → مشاكل Android
   - `Flutter not found` → مشاكل الإعداد

3. **الحل:**
   ```bash
   # أصلح الملف محلياً
   git add .
   git commit -m "fix: build error"
   git push
   # سيحاول البناء مرة أخرى
   ```

### Log كامل:

```
Actions → Latest Build → build job → scroll down
```

---

## 🎯 خلاصة الخطوات

```bash
# 1. إعداد محلي
cd camera_parent
git init
git add .
git commit -m "Initial commit"

# 2. على GitHub
# إنشاء repo جديد

# 3. ربط ودفع
git remote add origin https://github.com/YOU/camera_parent.git
git branch -M main
git push -u origin main

# 4. مراقبة البناء
# https://github.com/YOU/camera_parent/actions

# 5. تحميل APK
# من الـ artifacts أو releases
```

---

## 📁 الملفات المطلوبة

✅ **جميعها موجودة بالفعل:**

```
camera_parent/
├── .github/
│   └── workflows/
│       └── build_and_release.yml    ← GitHub Actions
├── lib/
├── android/
├── server/
├── pubspec.yaml
└── ... (ملفات أخرى)
```

---

## ⚙️ إذا أردت تخصيص الـ Workflow:

افتح `.github/workflows/build_and_release.yml` وعدّل:

```yaml
# تغيير version
flutter-version: '3.44.0'

# تغيير branches التي تشغّل البناء
on:
  push:
    branches:
      - main
      - develop

# إضافة secrets (مثل signing keys)
# راجع أدناه
```

---

## 🔐 Security & Signing (اختياري)

### إذا أردت توقيع APK:

1. أنشئ keystore محليّاً:
```bash
keytool -genkey -v -keystore camera_parent.keystore \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias camera_parent
```

2. أضفه إلى GitHub Secrets:
   - Settings → Secrets and variables → Actions
   - إضافة:
     - `KEYSTORE_BASE64` (ملف keystore مشفر)
     - `KEYSTORE_PASSWORD`
     - `KEY_ALIAS`
     - `KEY_PASSWORD`

3. استخدمه في workflow (متقدم)

---

## ✨ نصائح مهمة

✅ **افعل:**
- استخدم meaningful commit messages
- اختبر محليّاً قبل الـ push
- استخدم tags للـ releases الرسمية
- احفظ APKs من الـ artifacts

❌ **لا تفعل:**
- لا تضع keystore في الـ repo
- لا تضع secrets في الـ code
- لا تنسَ الـ personal access token

---

## 🎉 خلاصة البناء على GitHub

| الخطوة | الوقت | الملاحظة |
|-------|-------|---------|
| إعداد local | 5 دقائق | git init + commit |
| إنشاء GitHub repo | 2 دقيقة | من الويب |
| رفع الملفات | 1 دقيقة | git push |
| **البناء الأول** | **5-10 دقائق** | **في GitHub Actions** |
| تحميل APK | 1 دقيقة | من Artifacts |

---

## 🚀 الآن أنت جاهز!

```bash
# ملخص الأوامر:
cd camera_parent
git remote add origin https://github.com/YOU/camera_parent.git
git branch -M main
git push -u origin main

# ثم:
# 👉 افتح https://github.com/YOU/camera_parent/actions
# 👉 شاهد البناء يجري
# 👉 حمّل APK بعد انتهاءه
```

---

**لديك أي أسئلة؟ أخبرني!** 💬

