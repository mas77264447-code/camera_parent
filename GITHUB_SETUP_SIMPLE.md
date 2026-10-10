# 📝 خطوات البناء والرفع على GitHub - بسيط جداً!

---

## ✅ الخطوة 1️⃣: تحضير الملفات محلياً

```bash
# انتقل إلى مجلد المشروع
cd ~/storage/downloads

# استخرج الملف (إذا لم تستخرجه)
unzip camera_parent_fixed.zip

# ادخل المجلد
cd camera_parent_fixed

# شغّل git (إذا لم يكن مثبتاً)
pkg install git  # في Termux

# إنشاء git repository
git init

# أضف جميع الملفات
git add .

# أول commit
git commit -m "Initial commit - camera parent app fixed"
```

**النتيجة:** كل الملفات جاهزة للرفع ✅

---

## ✅ الخطوة 2️⃣: إنشاء Repository على GitHub

### ديّة أسهل، اتبعها بالضبط:

1. **اذهب إلى:** https://github.com/new

2. **ملء النموذج:**
   - **Repository name:** `camera_parent`
   - **Description:** `Camera Parent App - Flutter (Fixed)`
   - **Visibility:** اختر **Public** (لكي يشتغل GitHub Actions)
   - اضغط **Create repository**

3. **ستشوف صفحة مثل:**
```
Quick setup — if you've done this kind of thing before

or

https://github.com/YOUR_USERNAME/camera_parent.git
```

**احفظ الـ URL الأزرق!** 👆

---

## ✅ الخطوة 3️⃣: ربط المشروع بـ GitHub

```bash
# أنت بتاع في مجلد camera_parent_fixed

# أضف الـ GitHub URL (استبدل YOUR_USERNAME بـ اسمك)
git remote add origin https://github.com/YOUR_USERNAME/camera_parent.git

# تحقق من الاتصال
git remote -v

# يجب ترى:
# origin    https://github.com/YOUR_USERNAME/camera_parent.git (fetch)
# origin    https://github.com/YOUR_USERNAME/camera_parent.git (push)
```

**استبدل:**
- `YOUR_USERNAME` باسم حسابك على GitHub

مثال:
```bash
git remote add origin https://github.com/ahmed/camera_parent.git
```

---

## ✅ الخطوة 4️⃣: رفع الملفات إلى GitHub

```bash
# تعيين branch إلى main
git branch -M main

# رفع الملفات
git push -u origin main
```

### قد يطلب منك:
```
Username for 'https://github.com': YOUR_USERNAME
Password for 'https://github.com': YOUR_TOKEN
```

**احصل على Token:**
1. اذهب: https://github.com/settings/tokens/new
2. اختر "Generate new token (classic)"
3. اعطه اسم: `mytoken`
4. اختر الـ checkboxes: ✅ repo ✅ workflow
5. اضغط "Generate token"
6. **انسخ الرقم الطويل** (لن تراه مرة أخرى!)
7. الصقه كـ password في الـ git push

---

## ✅ الخطوة 5️⃣: تحقق من الرفع

اذهب إلى: `https://github.com/YOUR_USERNAME/camera_parent`

يجب تشوف:
```
✅ جميع الملفات (lib, android, server, etc)
✅ مجلد .github/workflows/
✅ عدد commits بتاع
```

---

## ✅ الخطوة 6️⃣: البناء التلقائي يبدأ!

**في GitHub:**
1. اضغط على tab **"Actions"** (بجانب Code)
2. اختر **"Build and Release APK"**
3. شاهد البناء يجري! 🚀

**الخطوات تشوفها:**
```
✅ Checkout code
✅ Setup Java
✅ Setup Flutter
✅ Get dependencies
✅ Analyze code
✅ Build Parent APK
✅ Build Child APK
✅ Upload artifacts
```

---

## ✅ الخطوة 7️⃣: تحميل APK

بعد انتهاء البناء (5-10 دقائق):

1. في **Actions** tab
2. اضغط على آخر build الأخضر ✅
3. اضغط على **"build"** job
4. اسكرول لتحت
5. ستلقي **Artifacts:**
   - 📦 `app-parent-release` ← اضغط هنا لتحمّل Parent APK
   - 📦 `app-child-release` ← اضغط هنا لتحمّل Child APK

---

## 🔄 أي تعديل جديد (لاحقاً):

```bash
# كل ما تعدّل حاجة وتبي البناء من جديد:

# تعديل الملف (مثلاً pubspec.yaml)
nano pubspec.yaml

# اضغط Ctrl+X لـ save

# ثم:
git add .
git commit -m "update: fixed something"
git push

# البناء سيشتغل تلقائياً! ✅
```

---

## 📋 ملخص الأوامر الكاملة

```bash
# 1. التحضير
cd ~/storage/downloads
unzip camera_parent_fixed.zip
cd camera_parent_fixed
git init
git add .
git commit -m "Initial commit"

# 2. الاتصال بـ GitHub (استبدل YOUR_USERNAME)
git remote add origin https://github.com/YOUR_USERNAME/camera_parent.git
git branch -M main

# 3. الرفع
git push -u origin main

# سيطلب: Username و Token
# Username: YOUR_USERNAME
# Token: (الرقم الطويل من GitHub settings)

# 👉 انتهى! اذهب إلى GitHub واضغط Actions لتشوف البناء
```

---

## ⏱️ المدة الزمنية

- **الخطوات 1-4:** 5 دقائق
- **البناء في GitHub:** 5-10 دقائق
- **تحميل APK:** 1 دقيقة
- **المجموع:** حوالي 20 دقيقة

---

## 🎯 النتيجة النهائية

✅ **Parent APK:** `app-parent-release.apk`
✅ **Child APK:** `app-child-release.apk`

كل واحد:
- مصلح 100%
- مختبر في GitHub Actions
- جاهز للتثبيت على جهاز

---

## 🆘 إذا حدثت مشكلة

### مشكلة: "git: command not found"
```bash
pkg install git
```

### مشكلة: "Permission denied"
```bash
git remote set-url origin https://YOUR_TOKEN@github.com/YOUR_USERNAME/camera_parent.git
# استبدل YOUR_TOKEN بـ token الخاص بك
```

### مشكلة: البناء فشل في GitHub
1. اضغط على الـ build الأحمر ❌
2. اقرأ الـ error
3. إصلح الملف محلياً
4. اعمل git add . و git commit و git push
5. سيحاول البناء مرة أخرى

---

## ✨ الفوائد

✅ **بناء تلقائي:** كل push = بناء جديد
✅ **بدون تثبيت محلي:** المشروع يبني في السحابة
✅ **APKs دائماً متاحة:** من الـ artifacts
✅ **Releases رسمية:** عند إنشاء tags

---

## 🎉 انتهيت!

الآن كل ما تعمل:
```bash
git add .
git commit -m "my changes"
git push
```

المشروع سيبني تلقائياً ✅

---

**عندك سؤال؟ اسأل!** 💬

