<div dir="rtl">

# Plan C

راه‌اندازی VLESS + WebSocket + TLS از طریق AWS CloudFront با استفاده از یک دامنه alias  به‌عنوان SNI.

این متود شبیه به متود بردن دامنه پشت cloudflare هستش ولی با استفاده از cloudfront.

جند نکته قبل از شروع:

>این متود تنها در صورتی کار میکنه که آیپی وایت برای cloudfront وجود داشته باشه در آخر در مورد روش ییدا کردن آیپی ها توضیح دادم

>به دلیل اینکه cloudfront بسته به موقعیت سرور شما از نود نزدیک به اون مکان استفاده میکنه. ممکنه آیپی وایت و سرور شما بااز نظر مکانی باهم همحونی نداشته باشه و ارتباط برفرار نشه. موقعیت مکانی آیپی وایت رو قبل از خرید سرور و تعیین ریحن مکان distribution رو چک کنید (توضیحات در مراحل بعد)

>به دلیل ایتکه خیلیا با cloudflare دامته هاشون رو مدیریت میکنن این اسکریپت طوری طراحی شده که شما نیاز نیس مدیریت دامنه اصلیتون رو به آمازون بدید و تنها زیردامنه از سرویس آمازون استفاده میکنه

اگه سوالی دارید در[ گروه تلگرام](https://t.me/The_Plan_C) بپرسید


---

## پیش‌نیازها

- یک دامنه با مدیریت در Cloudflare — [ساخت API Token](https://dash.cloudflare.com/profile/api-tokens) با مجوز `Zone:DNS:Edit`
- اکانت آمازون AWS
- سرور با دسترسی به اینترنت آزاد 

---

## (روش پیشنهادی) روش اول — اسکریپت خودکار

فایل`setup.sh` را روی سرور اجرا کنید. این اسکریپت مراحل زیر را به‌صورت خودکار انجام میده:

- ساخت رکوردهای `DNS`
- درخواست و اعتبارسنجی گواهی `ACM`
- تنظیم `CloudFront`
- دریافت گواهی `TLS` با `acme.sh`
- ساخت `inbound` در `x-ui`

### ۱. پر کردن فایل `.env`

```bash
cp .env.example .env
nano .env   # مقادیر جدول زیر رو وارد کنید
```

| متغیر | توضیح                                                                                                                      |
|---|----------------------------------------------------------------------------------------------------------------------------|
| `CF_TOKEN` | توکن API Cloudflare با مجوز `Zone:DNS:Edit` — [ساخت توکن](https://dash.cloudflare.com/profile/api-tokens)                  |
| `CF_ZONE_ID` | شناسه Zone دامنه در Cloudflare (به داشبورد برید و دامنه روانتخاب کنید سپس در پایین صفحه  سمت راست این آیدی رو پیدا میکنید) |
| `ROOT_DOMAIN` | دامنه اصلی، مثل `yourdomain.com`                                                                                           |
| `CDN_SUBDOMAIN` | زیردامنه CDN، مثل `cdn` — نتیجه: `cdn.yourdomain.com`                                                                      |
| `WS_PATH` | مسیر WebSocket؛ پیش‌فرض: `/videos/watch`                                                                                   |
| `INBOUND_PORT` | پورت inbound؛ پیش‌فرض: `443`                                                                                               |
| `X_UI_REMARK` | نام inbound در 3x-ui؛ پیش‌فرض: `vless-ws-tls-cf`                                                                           |
| `VLESS_UUID` | اختیاری؛ اگر خالی باشد، به‌صورت خودکار تولید می‌شود                                                                        |

### ۲. اجرای اسکریپت

```bash
chmod +x setup.sh
./setup.sh
```

اسکریپت پیشتیاز لازم (curl، jq، unzip، AWS CLI) را به‌صورت خودکار نصب می‌کنه. اگر AWS CLI نصب نباشه، دستور `aws login --remote` هم اجرا میشه — این دستور یک لینک و یک کد یک‌بارمصرف در ترمینال نمایش میده. آن لینک رو باز کنید، وارد کنسول AWS بشید و کد رو وارد کنید. پس از احراز هویت، اسکریپت به‌صورت خودکار ادامه میده.

---

## روش دوم — راه‌اندازی دستی

### مرحله ۱ — DNS در Cloudflare

دو رکورد زیر رو اضافه کنید. هر دو باید **بدون پروکسی** باشند (ابر خاکستری):

| نام | نوع | مقدار |
|---|---|---|
| `yourdomain.com` | A | IP سرور |
| `cdn.yourdomain.com` | CNAME | *(دامنه‌ی CloudFront از مرحله ۳)* |

رکورد A دامنه اصلی، origin CloudFront هستش. رکورد CNAME مربوط به `cdn` همان مقداری است که کلاینت در SNI میقرسته. این رکورد نباید از پروکسی Cloudflare عبور کنه، چون TLS در CloudFront انجام میشه.

---

### مرحله ۲ — گواهی ACM

قبل از این مرحله AWS CLI را نصب و وارد اکانت شید:

```bash
sudo apt update && sudo apt install -y unzip curl
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/ && /tmp/aws/install --update && rm -rf /tmp/aws /tmp/awscliv2.zip
```

سپس وارد اکانت AWS شوید. دستور زیر یک لینک و کد نمایش میده — آن لینک را روی دستگاه دیگری باز کنید، وارد کنسول AWS بشید و کد را وارد کنید:

```bash
aws login --remote
```

بعد گواهی ACM بسازید. CloudFront فقط گواهی صادرشده در **us-east-1** را قبول میکنه:

```bash
aws acm request-certificate \
  --region us-east-1 \
  --domain-name cdn.yourdomain.com \
  --validation-method DNS
```

ACM یک رکورد CNAME برمیگردونه. اون رو در Cloudflare DNS اضافه کنید (بدون پروکسی) و منتظر بمونید تا وضعیت به `ISSUED` تغییر کنخ:

```bash
aws acm describe-certificate --region us-east-1 \
  --certificate-arn <arn> \
  --query 'Certificate.Status'
```

---

### مرحله ۳ — توزیع CloudFront

در کنسول AWS یک distribution بسازید و فیلدها را به این شکل پر کنید:

#### فیلدهای اصلی

| فیلد در کنسول | مقدار |
|---|---|
| Distribution name | اختیاری؛ هر نامی که می‌خواهید، مثلاً `vless-ws-cf` |
| Description | اختیاری؛ خالی بگذارید یا چیزی مثل `VLESS WS TLS via CloudFront` بنویسید |
| Distribution type | `Single website or app` |
| Route 53 managed domain | رد کنید / خالی بگذارید |
| Tags | اختیاری |
| Origin type | `Other` |
| Origin | `yourdomain.com` |
| Origin path | خالی بگذارید |
| Allow private S3 bucket access to CloudFront | کاربردی ندارد؛ غیرفعال بماند |
| Origin settings | `Customize origin settings` |
| Cache settings | `Customize cache settings` |
| WAF | اختیاری؛ مگر اینکه خودتان بخواهید، روی حالت پیش‌فرض / غیرفعال بماند |

#### Customize origin settings

| فیلد در کنسول | مقدار |
|---|---|
| Enable origin mutual TLS | غیرفعال |
| Add custom header | خالی بگذارید |
| Origin Shield | غیرفعال |
| Protocol | `HTTPS only` |
| HTTPS port | `443` |
| Minimum origin SSL protocol | `TLSv1.2` |
| Connection attempts | `3` |
| Connection timeout | `10` ثانیه |
| Response timeout | `60` ثانیه |
| Keep-alive timeout | `60` ثانیه |
| Response completion timeout | غیرفعال |
| Origin IP address type | `IPv4-only` |

#### Customize cache settings

| فیلد در کنسول | مقدار |
|---|---|
| Viewer protocol policy | `HTTPS only` |
| Allowed HTTP methods | `GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE` |
| Cache HTTP methods | `GET and HEAD` |
| Allow gRPC requests over HTTP/2 | غیرفعال |
| Cache policy | `CachingDisabled` |
| Origin request policy | `AllViewerExceptHostHeader` |
| Response headers policy | خالی / none |

نکته‌ها:

- مقدار `Origin` باید دامنه اصلی یعنی `yourdomain.com` باشه، نه `cdn.yourdomain.com`.
- `Origin type` باید `Other` باشه، چون سرور شما یک origin  HTTPS است و از نوع S3 یا ELB یا API Gateway نیست.
- `HTTP version` در فرم اولیه بالا نیست. بعد از ساخت distribution آن را روی فقط `HTTP/1.1` بگذارید. `HTTP/2` باعث مبشه WebSocket upgrade در CloudFront  خراب شه.
- همچنین مطمئن شوید alternate domain همان `cdn.yourdomain.com` باشد و گواهی ACM مرحله ۲ روی distribution انتخاب شده باشد.

بعد از ساخت distribution، دامنه آن (مثل `xxxx.cloudfront.net`) را کپی کنید و رکورد CNAME مربوط به `cdn.yourdomain.com` را در Cloudflare روی آن تنظیم کنید.

#### قیمت پلن های CloudFront

CloudFront در حالت pay-as-you-go یک **قسمت رایگان دائمی** داره (نه آزمایشی ۱۲ ماهه):

- ۱ ترابایت انتقال داده در ماه
- ۱۰ میلیون درخواست HTTP/HTTPS در ماه

برای یک VPN شخصی به احتمال زیاد از این سقف رد نمیشید.

**Price class** تعیین میکنه از کدام Edge Locationها استفاده بشه. این روی نرخ هر گیگابایت *اگر* از سقف رایگان رد شید تأثیر دارد:

| Price Class | Edge Locationهای شامل | نرخ بعد از سقف رایگان |
|---|---|---|
| `PriceClass_100` | آمریکا، مکزیک، کانادا، اروپا، اسرائیل، ترکیه | $0.085/GB |
| `PriceClass_200` | موارد بالا + ژاپن، آسیا، هند، خاورمیانه | متوسط |
| `PriceClass_All` | همه مناطق (+ آمریکای جنوبی، استرالیا) | بیشترین |

ابن اسکریپت از `PriceClass_100` استفاده میکنه. کلاینت‌های خارج از این مناطق باز هم وصل میشند، اما CloudFront آن‌ها را از نزدیک‌ترین Edge Location موجود در این price class مسیریابی می‌کند، نه نزدیک‌ترین نقطه جهانی — ممکنه  کمی تأخیر بیشتری داشته باشند. اگر نیاز به پوشش جهانی کامل دارید، price class را در `setup.sh` تغییر بدید.

---

### مرحله ۴ — گواهی TLS روی سرور

این گواهی برای اتصال **CloudFront → VPS** در بخش origin استفاده میشه. CloudFront از طریق HTTPS به `yourdomain.com:443` وصل می‌شود و فقط گواهی‌ای را می‌پذیرد که توسط CA معتبر عمومی صادر شده باشد؛ بنابراین باید از یک گواهی واقعی مثل Let's Encrypt استفاده کنید. گواهی self-signed توسط CloudFront رد می‌شود.

گواهی باید هر دو دامنه `yourdomain.com` و `cdn.yourdomain.com` را پوشش بده.

```bash
curl -s https://get.acme.sh | sh
export CF_Token="<توکن-cloudflare-با-مجوز-Zone:DNS:Edit>"
~/.acme.sh/acme.sh --issue --dns dns_cf \
  -d yourdomain.com -d cdn.yourdomain.com \
  --fullchain-file /root/cert/domain/fullchain.pem \
  --key-file /root/cert/domain/privkey.pem \
  --reloadcmd 'systemctl restart x-ui'
```

---

### مرحله ۵ — Inbound در xray (3x-ui)

اگر 3x-ui از قبل نصب نشده :

```bash
bash -c "$(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh)"
```

یک inbound از نوع VLESS با تنظیمات زیر بسازید:

| تنظیم | مقدار |
|---|---|
| پروتکل | VLESS |
| پورت | ۴۴۳ |
| Transport | WebSocket |
| Path | `/videos/watch` |
| TLS | فعال |
| `serverName` | `cdn.yourdomain.com` |
| ALPN | فقط `http/1.1` |
| Certificate | `/root/cert/domain/fullchain.pem` |
| Key | `/root/cert/domain/privkey.pem` |
| `rejectUnknownSni` | false |
| Fingerprint | `random` |
| ECH | غیرفعال / خالی |

**ALPN باید حتماً فقط `http/1.1` باشد.** اضافه کردن `h2` باعث می‌شود CloudFront و xray روی HTTP/2 توافق کنند؛ در این حالت WebSocket upgrade پشتیبانی نمی‌شود.

برای افزودن inbound از طریق پنل 3x-ui، به **Inbounds → Add** بروید و این JSON را جای‌گذاری کنید. `yourdomain.com` و UUID را با مقادیر واقعی خودتان جایگزین کنید:

```json
{
  "remark": "vless-ws-tls-cf",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [{
      "id": "<generate-a-uuid>",
      "email": "user",
      "enable": true,
      "flow": "",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0
    }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "tls",
    "tlsSettings": {
      "serverName": "cdn.yourdomain.com",
      "alpn": ["http/1.1"],
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "certificates": [{
        "certificateFile": "/root/cert/domain/fullchain.pem",
        "keyFile": "/root/cert/domain/privkey.pem"
      }]
    },
    "wsSettings": {
      "path": "/videos/watch",
      "headers": {}
    }
  },
  "sniffing": {
    "enabled": false,
    "destOverride": ["http","tls","quic","fakedns"]
  }
}
```

سپس x-ui را ری‌استارت کنید: `systemctl restart x-ui`.

بررسی اتصال:
```bash
curl -sk --http1.1 \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Host: cdn.yourdomain.com" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  -o /dev/null -w "%{http_code}" \
  https://yourdomain.com/videos/watch
# خروجی مورد انتظار: 101
```

---

### مرحله ۶ — تنظیمات کلاینت

```
vless://<UUID>@WhiteListedIp:443?type=ws&path=%2Fvideos%2Fwatch&security=tls&sni=WhiteListedIp&host=cdn.yourdomain.com&alpn=http%2F1.1&fp=random&encryption=none#CloudFront-WS
```


نکته مهم : این روش در حال خاضر فقط با آیپی وایت کار میکنه.برای پیدا کردن آیپی وایت میتونید از این پروژه کمک بگیرید.

👉 **[https://github.com/thefourthmusketeer/cloudfront-scanner](https://github.com/thefourthmusketeer/cloudfront-scanner)**


در آخر:

"دگران کاشتند و ما خوردیم

ما بکاریم و دگران بخورند"

برای وصل ماندن به اینترنت به هم کمک کنیم. از هم سو استفاده نکنیم
</div>
