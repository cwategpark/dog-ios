import Foundation

/// Local dictionary based three-language UI copy (zh-CN / es / en).
enum L10n {
    static let supported = ["zh-CN", "es", "en"]

    static func t(_ key: String, _ language: String) -> String {
        guard let entry = table[key] else { return key }
        return entry[language] ?? entry["en"] ?? entry["zh-CN"] ?? key
    }

    static func t(_ key: String, _ language: String, _ args: CVarArg...) -> String {
        String(format: t(key, language), arguments: args)
    }

    // MARK: - Enum labels

    static func optionValueLabel(_ value: String, _ language: String) -> String {
        let key = "option.value.\(value)"
        let localized = t(key, language)
        return localized == key ? value : localized
    }

    static func optionNameLabel(_ name: String, _ language: String) -> String {
        let key = "option.name.\(name)"
        let localized = t(key, language)
        return localized == key ? name : localized
    }

    static func audienceLabel(_ code: String, _ language: String) -> String {
        let key = "audience.\(code)"
        let localized = t(key, language)
        return localized == key ? code : localized
    }

    static func sceneLabel(_ code: String, _ language: String) -> String {
        let key = "scene.\(code)"
        let localized = t(key, language)
        return localized == key ? code : localized
    }

    static func categoryLabel(_ code: String, _ language: String) -> String {
        let key = "category.\(code)"
        let localized = t(key, language)
        return localized == key ? code : localized
    }

    static func scopeLabel(_ scope: String, _ language: String) -> String {
        let key = "consent.scope.\(scope)"
        let localized = t(key, language)
        return localized == key ? scope : localized
    }

    static func stageLabel(_ stage: String, _ language: String) -> String {
        let key = "stage.\(stage)"
        let localized = t(key, language)
        return localized == key ? stage : localized
    }

    static func statusLabel(_ status: String, _ language: String) -> String {
        let key = "status.\(status)"
        let localized = t(key, language)
        return localized == key ? status : localized
    }

    static func speciesLabel(_ species: String, _ language: String) -> String {
        let key = "species.\(species)"
        let localized = t(key, language)
        return localized == key ? species : localized
    }

    static func dogSizeLabel(_ size: String, _ language: String) -> String {
        let key = "dogSize.\(size)"
        let localized = t(key, language)
        return localized == key ? size : localized
    }

    static func themeLabel(_ theme: String, _ language: String) -> String {
        t("theme.\(theme)", language)
    }

    static func privacyStatusLabel(_ status: String, _ language: String) -> String {
        let key = "privacy.status.\(status)"
        let localized = t(key, language)
        return localized == key ? status : localized
    }

    private static func tri(_ zh: String, _ es: String, _ en: String) -> [String: String] {
        ["zh-CN": zh, "es": es, "en": en]
    }

    static let table: [String: [String: String]] = [
        // General
        "app.name": tri("Pawly", "Pawly", "Pawly"),
        "brand.tagline": tri("为毛孩子，认真挑选", "Elegido con cariño para tu mascota", "Thoughtfully made for your best friend"),
        "demo.chip": tri("演示环境", "Demo", "Demo"),
        "demo.banner": tri("演示环境 · 数据为合成 · 未连接 Shopify / AI", "Entorno demo · datos sintéticos · sin Shopify ni IA real", "Demo environment · synthetic data · not connected to Shopify / AI"),
        "demo.global": tri("Demo · 未连接 Shopify / AI", "Demo · sin Shopify / IA", "Demo · not connected to Shopify / AI"),
        "action.retry": tri("重试", "Reintentar", "Retry"),
        "action.cancel": tri("取消", "Cancelar", "Cancel"),
        "action.done": tri("完成", "Listo", "Done"),
        "action.close": tri("关闭", "Cerrar", "Close"),
        "action.save": tri("保存", "Guardar", "Save"),
        "action.delete": tri("删除", "Eliminar", "Delete"),
        "action.add": tri("添加", "Añadir", "Add"),
        "action.refresh": tri("刷新", "Actualizar", "Refresh"),
        "action.back": tri("返回", "Volver", "Back"),
        "action.fromLibrary": tri("从相册选择", "Elegir de fotos", "Choose from library"),
        "common.loading": tri("加载中…", "Cargando…", "Loading…"),
        "common.empty": tri("暂无数据", "Sin datos", "No data"),
        "common.months": tri("%d 个月", "%d meses", "%d months"),
        "common.monthsShort": tri("%d 月龄", "%d meses", "%d mo"),
        "common.unknown": tri("未知", "Desconocido", "Unknown"),
        "common.optional": tri("选填", "Opcional", "Optional"),
        "common.currency": tri("USD", "USD", "USD"),

        // Errors
        "error.generic": tri("出了点问题，请重试", "Algo salió mal. Inténtalo de nuevo", "Something went wrong. Please try again."),
        "error.network": tri("无法连接 demo 后端（127.0.0.1:8788）。请确认后端已启动。", "No se pudo conectar al backend demo (127.0.0.1:8788). Comprueba que esté iniciado.", "Cannot reach the demo backend (127.0.0.1:8788). Make sure it is running."),
        "error.decoding": tri("服务返回的数据无法解析", "La respuesta del servicio no se pudo leer", "The service response could not be parsed."),
        "error.unauthorized": tri("登录状态已失效，请重新登录", "La sesión caducó. Vuelve a iniciar sesión.", "Your session expired. Please sign in again."),
        "error.retryable": tri("可以重试", "Puedes reintentar", "You can retry"),
        "error.conflict": tri("数据已在别处更新，已为你拉取最新版本", "Los datos cambiaron en otro sitio. Se cargó la última versión.", "The data changed elsewhere. The latest version was loaded."),
        "error.validation": tri("请检查填写内容", "Revisa los campos", "Please check the fields."),
        "error.stateConflict": tri("当前状态不允许该操作", "El estado actual no permite esta acción", "The current state does not allow this action."),
        "error.claimInvalid": tri("认领码无效或已过期", "Código de reclamación no válido o caducado", "Claim code is invalid or expired."),
        "error.claimConsumed": tri("认领码已被使用", "El código ya se usó", "This claim code was already used."),
        "error.required": tri("此项必填", "Obligatorio", "Required"),
        "error.field": tri("%@：%@", "%@: %@", "%@: %@"),

        // Login
        "login.title": tri("为毛孩子，认真挑选", "Elegido con cariño para tu mascota", "Thoughtfully made for your best friend"),
        "login.subtitle": tri("宠物用品商城 + 宠物数字形象\n同一个身份，同一个 demo 后端", "Tienda de mascotas + avatar digital\nUna identidad, un backend demo", "Pet shop + digital pet avatar\nOne identity, one demo backend"),
        "login.demoCustomer": tri("以演示 Shopify 客户登录", "Entrar como cliente Shopify demo", "Sign in as demo Shopify customer"),
        "login.demoCustomerHint": tri("demo@pawly.invalid · 陈小雨 · Milo 与阿福", "demo@pawly.invalid · 陈小雨 · Milo y 阿福", "demo@pawly.invalid · Chen Xiaoyu · Milo & Afu"),
        "login.guest": tri("游客浏览 / 填写", "Navegar como invitado", "Browse as guest"),
        "login.guestHint": tri("受限游客凭证，可浏览与创建自己的宠物", "Credencial de invitado con permisos limitados", "Limited guest credential for browsing and own pets"),
        "login.claimTitle": tri("输入认领码", "Código de reclamación", "Claim code"),
        "login.claimPlaceholder": tri("6 位数字", "6 dígitos", "6 digits"),
        "login.claimButton": tri("认领网站资料", "Reclamar perfil web", "Claim website profile"),
        "login.claimHint": tri("在网站完成问卷后获得 6 位认领码；认领会先以演示客户身份登录。", "Tras completar el cuestionario web recibirás un código de 6 dígitos.", "Complete the web questionnaire to get a 6-digit code. Claiming signs in the demo customer first."),
        "login.connecting": tri("登录中…", "Entrando…", "Signing in…"),
        "login.demoNote": tri("演示登录：固定 demo token 换取业务会话，未接真实 Shopify OAuth。", "Acceso demo: token fijo intercambiado por sesión; sin OAuth real de Shopify.", "Demo sign-in: fixed demo token exchanged for a business session; real Shopify OAuth is not connected."),
        "login.langLabel": tri("界面语言", "Idioma", "Language"),
        "login.connectedHint": tri("已连接 demo 后端", "Backend demo conectado", "Connected to demo backend"),
        "login.offlineHint": tri("未连接到 demo 后端（127.0.0.1:8788）", "Backend demo no disponible (127.0.0.1:8788)", "Demo backend unavailable (127.0.0.1:8788)"),

        // Tabs
        "tab.home": tri("首页", "Inicio", "Home"),
        "tab.shop": tri("商城", "Tienda", "Shop"),
        "tab.generate": tri("生成", "Crear", "Create"),
        "tab.profile": tri("我的", "Cuenta", "Account"),

        // Home
        "home.greeting": tri("你好，%@", "Hola, %@", "Hi, %@"),
        "home.greetingPlain": tri("你好", "Hola", "Hi there"),
        "home.subtitle": tri("今天也带 TA 出去走走吧", "¿Salimos a pasear hoy?", "Time for a walk today?"),
        "home.pets": tri("我的宠物", "Mis mascotas", "My pets"),
        "home.noPets": tri("还没有宠物档案", "Aún no hay mascotas", "No pet profiles yet"),
        "home.noPetsHint": tri("添加一只宠物，开始个性化推荐与形象生成。", "Añade una mascota para empezar.", "Add a pet to unlock recommendations and avatar generation."),
        "home.addPet": tri("添加宠物", "Añadir mascota", "Add pet"),
        "home.recommend": tri("为 %@ 推荐", "Recomendado para %@", "Recommended for %@"),
        "home.recommendFallback": tri("精选商品", "Productos destacados", "Featured picks"),
        "home.recommendFallbackNote": tri("暂无推荐记录，先展示精选商品", "Sin recomendaciones todavía; mostrando destacados", "No recommendation yet — showing featured products"),
        "home.featured": tri("精选商品", "Destacados", "Featured"),
        "home.viewAll": tri("查看全部", "Ver todo", "View all"),
        "home.demoTip": tri("演示提示：推荐与商品内容均来自 demo 后端（本地规则 + 种子投影），不是真实 Shopify 数据。", "Aviso demo: recomendaciones y productos vienen del backend demo.", "Demo note: recommendations and products come from the demo backend, not real Shopify data."),
        "home.claimCode": tri("游客认领码", "Código de invitado", "Guest claim code"),
        "home.claimCodeHint": tri("在网站完成问卷后，用此码在 iOS 登录页认领资料。", "Usa este código en la pantalla de acceso de iOS.", "Use this code on the iOS sign-in screen to claim the profile."),
        "home.hero.avatarCurrent": tri("当前形象", "Avatar actual", "Current avatar"),
        "home.hero.avatarNone": tri("渐变色占位形象", "Avatar de marcador", "Gradient placeholder avatar"),
        "home.hero.generate": tri("生成形象", "Crear avatar", "Create avatar"),
        "home.hero.viewPet": tri("宠物档案", "Ficha", "Pet profile"),
        "home.hero.breedUnknown": tri("品种待确认", "Raza por confirmar", "Breed to confirm"),
        "home.today": tri("今日精选", "Selección de hoy", "Today's picks"),

        // Shop
        "shop.title": tri("商城", "Tienda", "Shop"),
        "shop.search": tri("搜索商品", "Buscar productos", "Search products"),
        "shop.filter.audience": tri("受众", "Audiencia", "Audience"),
        "shop.filter.scene": tri("场景", "Escena", "Scene"),
        "shop.filter.category": tri("类目", "Categoría", "Category"),
        "shop.all": tri("全部", "Todo", "All"),
        "shop.sort.relevance": tri("综合", "Relevancia", "Relevance"),
        "shop.sort.priceAsc": tri("价格低到高", "Precio ↑", "Price low to high"),
        "shop.sort.priceDesc": tri("价格高到低", "Precio ↓", "Price high to low"),
        "shop.sort": tri("排序", "Ordenar", "Sort"),
        "shop.empty": tri("没有符合条件的商品", "No hay productos que coincidan", "No matching products"),
        "shop.emptyHint": tri("试试调整筛选或搜索词", "Prueba otros filtros o búsqueda", "Try adjusting filters or search"),
        "shop.loadMore": tri("加载更多", "Cargar más", "Load more"),
        "shop.end": tri("已经到底了", "No hay más", "That's everything"),
        "shop.count": tri("%d 件商品", "%d productos", "%d products"),
        "shop.demoNote": tri("演示商品目录 · 价格与可售性来自本地种子投影", "Catálogo demo · precios de proyección local", "Demo catalog · prices from local seed projection"),

        // Product detail
        "product.addToCart": tri("加入购物车", "Añadir al carrito", "Add to cart"),
        "product.adding": tri("加入中…", "Añadiendo…", "Adding…"),
        "product.added": tri("已加入购物车", "Añadido al carrito", "Added to cart"),
        "product.quantity": tri("数量", "Cantidad", "Quantity"),
        "product.description": tri("商品描述", "Descripción", "Description"),
        "product.fit": tri("适配参考", "Ajuste", "Fit guidance"),
        "product.capabilities": tri("3D 能力", "Capacidades 3D", "3D capabilities"),
        "product.glbReady": tri("GLB 演示资产就绪", "GLB demo listo", "GLB demo asset ready"),
        "product.glbNone": tri("无 GLB 资产", "Sin GLB", "No GLB asset"),
        "product.usdzUnavailable": tri("USDZ 暂不可用", "USDZ no disponible", "USDZ unavailable"),
        "product.skinning": tri("骨骼蒙皮", "Skinning", "Skinning"),
        "product.actions": tri("可用动作", "Acciones", "Actions"),
        "product.selectOptions": tri("请选择完整的选项组合", "Selecciona todas las opciones", "Select a complete option combination"),
        "product.unavailable": tri("该组合暂不可售", "Esta combinación no está disponible", "This combination is unavailable"),
        "product.compareAt": tri("原价", "Antes", "Was"),
        "product.people": tri("主人用品", "Para personas", "For people"),
        "product.image": tri("商品图片", "Imagen del producto", "Product image"),
        "product.demoNote": tri("演示商品 · 价格来自本地种子投影，未通过 Shopify 校验", "Producto demo · precio de proyección local", "Demo product · price from local seed projection"),
        "product.badge3d": tri("3D", "3D", "3D"),
        "product.options": tri("选项", "Opciones", "Options"),
        "product.youMayAlsoLike": tri("你可能也喜欢", "También te puede gustar", "You may also like"),
        "product.from": tri("起", "desde", "from"),

        // Cart
        "cart.title": tri("购物车", "Carrito", "Cart"),
        "cart.empty": tri("购物车还是空的", "El carrito está vacío", "Your cart is empty"),
        "cart.emptyHint": tri("去商城挑选适合 TA 的用品吧", "Encuentra algo para tu mascota", "Find something for your pet"),
        "cart.browse": tri("去逛逛", "Explorar", "Browse shop"),
        "cart.subtotal": tri("小计", "Subtotal", "Subtotal"),
        "cart.total": tri("合计", "Total", "Total"),
        "cart.itemCount": tri("%d 件", "%d artículos", "%d items"),
        "cart.remove": tri("移除", "Quitar", "Remove"),
        "cart.checkout": tri("演示 Checkout", "Checkout demo", "Demo checkout"),
        "cart.checkoutNote": tri("演示结算：只有点击「模拟支付完成」并调用 confirm 后才会显示已支付；关闭不会改变状态。", "Checkout demo: solo se marca pagado tras confirmar.", "Demo checkout: paid is shown only after confirm; closing changes nothing."),
        "cart.discount": tri("演示优惠", "Descuento demo", "Demo discount"),
        "cart.discountEligible": tri("符合演示优惠条件", "Cumple la promoción demo", "Eligible for demo discount"),
        "cart.discountNotEligible": tri("演示优惠未生效", "Promoción demo no aplicada", "Demo discount not applied"),
        "cart.discountNote": tri("演示规则，未接入 Shopify", "Regla demo, sin Shopify", "Demo rule, not connected to Shopify"),
        "cart.customization": tri("宠物定制", "Personalización", "Pet customization"),
        "cart.warnings": tri("提示", "Avisos", "Warnings"),
        "cart.resolving": tri("正在获取购物车…", "Cargando carrito…", "Loading cart…"),
        "cart.updating": tri("更新中…", "Actualizando…", "Updating…"),
        "cart.line.title": tri("商品", "Producto", "Product"),
        "cart.checkoutCreating": tri("正在创建演示结账…", "Creando checkout demo…", "Creating demo checkout…"),
        "cart.emptyVariant": tri("暂不可售", "No disponible", "Unavailable"),

        // Checkout
        "checkout.title": tri("演示结账", "Checkout demo", "Demo checkout"),
        "checkout.summary": tri("订单摘要", "Resumen", "Order summary"),
        "checkout.payDemo": tri("模拟支付完成", "Simular pago", "Simulate payment"),
        "checkout.paying": tri("正在确认…", "Confirmando…", "Confirming…"),
        "checkout.unpaid": tri("尚未支付", "Aún sin pagar", "Not paid yet"),
        "checkout.unpaidHint": tri("只有调用 confirm 后订单才会变成已支付；关闭此页不会自动已付。", "El pedido solo pasa a pagado al confirmar; cerrar no lo marca.", "The order becomes paid only after confirm; closing does not mark it paid."),
        "checkout.paid": tri("订单已支付（演示）", "Pedido pagado (demo)", "Order paid (demo)"),
        "checkout.paidHint": tri("由本地 demo 后端模拟支付与 Webhook，未接入真实 Shopify 支付。", "Pago y webhook simulados por el backend demo.", "Payment and webhook are simulated by the local demo backend."),
        "checkout.orderId": tri("订单号", "Pedido", "Order"),
        "checkout.total": tri("合计", "Total", "Total"),
        "checkout.sessionStatus": tri("会话状态", "Estado de sesión", "Session status"),
        "checkout.confirming": tri("正在调用 confirm…", "Llamando a confirm…", "Calling confirm…"),
        "checkout.confirmError": tri("确认支付失败，订单仍未支付", "No se pudo confirmar; el pedido sigue sin pagar", "Confirmation failed; the order is still unpaid."),
        "checkout.status.open": tri("进行中", "Abierta", "Open"),
        "checkout.status.confirmed": tri("已确认", "Confirmada", "Confirmed"),
        "checkout.status.expired": tri("已过期", "Caducada", "Expired"),
        "checkout.issuedAt": tri("签发时间", "Emitido", "Issued"),
        "checkout.orderStatus": tri("订单状态", "Estado del pedido", "Order status"),
        "checkout.paidAt": tri("支付时间", "Pagado el", "Paid at"),

        // Generate
        "generate.title": tri("生成形象", "Crear avatar", "Create avatar"),
        "generate.subtitle": tri("上传一张照片，生成可动画的宠物数字形象（演示）", "Sube una foto y genera un avatar animable (demo)", "Upload a photo to generate an animatable pet avatar (demo)"),
        "generate.step.pet": tri("1 · 选择宠物", "1 · Mascota", "1 · Choose pet"),
        "generate.step.photo": tri("2 · 选择照片", "2 · Foto", "2 · Choose photo"),
        "generate.step.consent": tri("3 · 授权确认", "3 · Consentimiento", "3 · Consent"),
        "generate.photo.cat": tri("猫样张", "Muestra gato", "Cat sample"),
        "generate.photo.dog": tri("狗样张", "Muestra perro", "Dog sample"),
        "generate.photo.hint": tri("演示用内置合成样张；模拟器无照片库，另提供从相册选择。", "Muestras sintéticas incluidas; también puedes elegir de fotos.", "Built-in synthetic samples; you can also pick from the photo library."),
        "generate.consent.photo": tri("同意上传并处理这张照片（photo_processing）", "Acepto subir y procesar esta foto (photo_processing)", "I consent to uploading and processing this photo (photo_processing)"),
        "generate.consent.model": tri("同意使用模板生成宠物形象（model_generation）", "Acepto generar el avatar con la plantilla (model_generation)", "I consent to generating the avatar with the template (model_generation)"),
        "generate.consentHint": tri("两项同意默认开启，未全部勾选不能提交；同意记录追加写入，可在「我的 · 同意记录」查看。", "Ambos consentimientos están activos por defecto.", "Both consents are on by default; all are required to submit."),
        "generate.submit": tri("开始生成", "Generar", "Start generation"),
        "generate.submitting": tri("提交中…", "Enviando…", "Submitting…"),
        "generate.uploading": tri("上传照片…", "Subiendo foto…", "Uploading photo…"),
        "generate.completing": tri("校验照片…", "Validando foto…", "Validating photo…"),
        "generate.creating": tri("创建生成任务…", "Creando tarea…", "Creating job…"),
        "generate.polling": tri("生成中，请稍候…", "Generando…", "Generating…"),
        "generate.resultTitle": tri("生成进度", "Progreso", "Progress"),
        "generate.successTitle": tri("生成结果", "Resultado", "Result"),
        "generate.stage": tri("当前阶段", "Etapa", "Stage"),
        "generate.progress": tri("%d%%", "%d%%", "%d%%"),
        "generate.succeeded": tri("生成完成（演示）", "Generación completada (demo)", "Generation complete (demo)"),
        "generate.poster": tri("海报", "Póster", "Poster"),
        "generate.glb": tri("GLB 模型", "Modelo GLB", "GLB model"),
        "generate.manifest": tri("manifest", "Manifest", "Manifest"),
        "generate.usdz": tri("USDZ", "USDZ", "USDZ"),
        "generate.ready": tri("就绪", "Listo", "Ready"),
        "generate.failed": tri("不可用", "No disponible", "Unavailable"),
        "generate.pending": tri("生成中", "Generando", "Generating"),
        "generate.downgrade": tri("USDZ 暂不可用：静态形象、海报与购买仍可继续。这是 demo 的能力降级展示。", "USDZ no disponible: el avatar estático y la compra siguen funcionando.", "USDZ unavailable: the static avatar and shopping still work. This is the demo capability downgrade."),
        "generate.idleTitle": tri("还没有开始", "Aún sin empezar", "Not started yet"),
        "generate.idleHint": tri("选择宠物与照片，勾选授权后开始生成。", "Elige mascota y foto, acepta y genera.", "Choose a pet and photo, accept consents, then start."),
        "generate.history": tri("生成历史", "Historial", "History"),
        "generate.historyEmpty": tri("暂无生成记录", "Sin generaciones", "No generation history"),
        "generate.cancel": tri("取消任务", "Cancelar tarea", "Cancel job"),
        "generate.cancelled": tri("已请求取消", "Cancelación solicitada", "Cancellation requested"),
        "generate.retry": tri("重新生成", "Generar de nuevo", "Generate again"),
        "generate.error.consent": tri("请先勾选两项授权", "Acepta ambos consentimientos", "Please accept both consents"),
        "generate.error.noPet": tri("请先选择宠物", "Elige una mascota", "Please choose a pet"),
        "generate.error.noPhoto": tri("请选择一张照片", "Elige una foto", "Please choose a photo"),
        "generate.avatarUpdated": tri("宠物形象已更新", "Avatar de la mascota actualizado", "Pet avatar updated"),
        "generate.posterTap": tri("点击查看大图", "Toca para ampliar", "Tap to enlarge"),
        "generate.usdzError": tri("转换器不可用（USDZ_CONVERTER_UNAVAILABLE）", "Convertidor no disponible", "Converter unavailable"),
        "generate.noTemplate": tri("没有可用的生成模板", "No hay plantilla disponible", "No generation template available"),

        // Profile
        "profile.title": tri("我的", "Cuenta", "Account"),
        "profile.account": tri("账户资料", "Perfil", "Profile"),
        "profile.edit": tri("编辑", "Editar", "Edit"),
        "profile.email": tri("邮箱", "Correo", "Email"),
        "profile.name": tri("姓名", "Nombre", "Full name"),
        "profile.save": tri("保存资料", "Guardar", "Save profile"),
        "profile.saving": tri("保存中…", "Guardando…", "Saving…"),
        "profile.saved": tri("资料已保存（revision +1）", "Perfil guardado", "Profile saved"),
        "profile.conflict": tri("资料已在别处更新（412），已拉取最新版本，请确认后重试。", "Los datos cambiaron (412). Se cargó la última versión.", "Profile changed elsewhere (412). Latest version loaded — retry."),
        "profile.notVerified": tri("邮箱未验证", "Correo sin verificar", "Email not verified"),
        "profile.verified": tri("邮箱已验证", "Correo verificado", "Email verified"),
        "profile.pets": tri("宠物档案", "Mascotas", "Pets"),
        "profile.pet.age": tri("%d 月龄", "%d meses", "%d mo"),
        "profile.pet.measurements": tri("体尺（cm / kg）", "Medidas (cm / kg)", "Measurements (cm / kg)"),
        "profile.pet.neck": tri("颈围", "Cuello", "Neck"),
        "profile.pet.chest": tri("胸围", "Pecho", "Chest"),
        "profile.pet.back": tri("背长", "Lomo", "Back"),
        "profile.pet.weight": tri("体重", "Peso", "Weight"),
        "profile.pet.unknown": tri("未知", "Desconocido", "Unknown"),
        "profile.pet.current": tri("当前", "Actual", "Current"),
        "profile.pet.switch": tri("切换", "Cambiar", "Switch"),
        "profile.consents": tri("同意记录", "Consentimientos", "Consents"),
        "profile.consents.empty": tri("暂无同意记录", "Sin consentimientos", "No consents yet"),
        "profile.consents.granted": tri("已同意", "Concedido", "Granted"),
        "profile.consents.withdrawn": tri("已撤回", "Retirado", "Withdrawn"),
        "profile.preferences": tri("偏好设置", "Preferencias", "Preferences"),
        "profile.language": tri("语言", "Idioma", "Language"),
        "profile.theme": tri("外观", "Tema", "Theme"),
        "profile.appearance": tri("外观配置", "Apariencia", "Appearance"),
        "profile.appearance.release": tri("release_id", "release_id", "release_id"),
        "profile.appearance.revision": tri("head_revision", "head_revision", "head_revision"),
        "profile.appearance.renderer": tri("renderer", "renderer", "renderer"),
        "profile.appearance.channel": tri("渠道", "Canal", "Channel"),
        "profile.appearance.reload": tri("重新拉取外观", "Recargar apariencia", "Reload appearance"),
        "profile.appearance.loaded": tri("外观已从后端重新拉取", "Apariencia recargada", "Appearance reloaded"),
        "profile.privacy": tri("隐私请求", "Privacidad", "Privacy requests"),
        "profile.privacy.export": tri("申请数据导出", "Solicitar exportación", "Request data export"),
        "profile.privacy.delete": tri("申请注销账户", "Solicitar eliminación", "Request account deletion"),
        "profile.privacy.note": tri("演示：只记录请求状态，不执行真实删除；订单财务记录保留。", "Demo: solo se registra el estado; no se borra nada realmente.", "Demo: only request status is recorded; nothing is really deleted."),
        "profile.privacy.requested": tri("已创建请求 %@", "Solicitud creada %@", "Request created %@"),
        "profile.privacy.status": tri("状态", "Estado", "Status"),
        "profile.privacy.polling": tri("查询状态中…", "Consultando…", "Checking status…"),
        "profile.logout": tri("退出登录", "Cerrar sesión", "Sign out"),
        "profile.logoutConfirm": tri("确定退出登录？将清除本地 token 与缓存，并撤销当前会话。", "¿Cerrar sesión? Se borrarán token y caché locales.", "Sign out? The local token and cache will be cleared and the session revoked."),
        "profile.demoEnv": tri("Demo 环境说明", "Notas del entorno demo", "Demo environment notes"),
        "profile.demoEnvText": tri("登录使用固定 demo token 交换业务会话；商品、价格、购物车、结账、AI/3D 生成全部为本地模拟，未连接 Shopify 或真实 AI 供应商。", "El acceso usa un token demo fijo; catálogo, carrito, checkout y generación son simulados.", "Sign-in uses a fixed demo token. Catalog, cart, checkout and AI/3D generation are all simulated locally."),
        "profile.claimCode": tri("游客认领码", "Código de invitado", "Guest claim code"),
        "profile.subject.kind.customer": tri("演示客户", "Cliente demo", "Demo customer"),
        "profile.subject.kind.guest": tri("受限游客", "Invitado", "Guest"),
        "profile.revision": tri("revision %@", "revisión %@", "revision %@"),
        "profile.addPet": tri("添加宠物", "Añadir mascota", "Add pet"),
        "profile.pets.hint": tri("点击卡片切换首页当前宠物", "Toca para cambiar la mascota activa", "Tap a card to switch the active pet"),
        "profile.about": tri("关于", "Acerca de", "About"),
        "profile.appVersion": tri("App 版本", "Versión", "App version"),

        // Add pet
        "addPet.title": tri("添加宠物", "Añadir mascota", "Add pet"),
        "addPet.name": tri("宠物名", "Nombre", "Pet name"),
        "addPet.namePlaceholder": tri("例如：Milo", "p. ej. Milo", "e.g. Milo"),
        "addPet.species": tri("种类", "Especie", "Species"),
        "addPet.dogSize": tri("犬型", "Tamaño", "Dog size"),
        "addPet.age": tri("月龄", "Meses", "Age (months)"),
        "addPet.save": tri("保存宠物", "Guardar mascota", "Save pet"),
        "addPet.error.name": tri("请填写宠物名", "Indica el nombre", "Please enter a pet name"),
        "addPet.saved": tri("宠物已添加", "Mascota añadida", "Pet added"),

        // Enums
        "species.cat": tri("猫", "Gato", "Cat"),
        "species.dog": tri("狗", "Perro", "Dog"),
        "species.other": tri("其它", "Otro", "Other"),
        "dogSize.small": tri("小型", "Pequeño", "Small"),
        "dogSize.medium": tri("中型", "Mediano", "Medium"),
        "dogSize.large": tri("大型", "Grande", "Large"),
        "dogSize.unknown": tri("未知", "Desconocido", "Unknown"),
        "audience.cat": tri("猫", "Gatos", "Cats"),
        "audience.dog": tri("狗", "Perros", "Dogs"),
        "audience.people": tri("主人", "Personas", "People"),
        "scene.daily": tri("日常", "Diario", "Daily"),
        "scene.outdoor": tri("户外", "Exterior", "Outdoor"),
        "scene.travel": tri("旅行", "Viaje", "Travel"),
        "category.harness": tri("胸背带", "Arnés", "Harness"),
        "category.vest": tri("背心", "Chaleco", "Vest"),
        "category.collar": tri("项圈", "Collar", "Collar"),
        "category.leash": tri("牵引绳", "Correa", "Leash"),
        "category.bed": tri("床窝", "Cama", "Bed"),
        "category.bowl": tri("食碗", "Cuenco", "Bowl"),
        "category.toy": tri("玩具", "Juguete", "Toy"),
        "category.bag": tri("包袋", "Bolso", "Bag"),
        "category.raincoat": tri("雨衣", "Impermeable", "Raincoat"),
        "option.name.color": tri("颜色", "Color", "Color"),
        "option.name.size": tri("尺码", "Talla", "Size"),
        "option.value.black": tri("曜石黑", "Negro", "Black"),
        "option.value.orange": tri("活力橙", "Naranja", "Orange"),
        "option.value.cream": tri("奶油白", "Crema", "Cream"),
        "option.value.sage": tri("鼠尾草", "Salvia", "Sage"),
        "option.value.blush": tri("腮红粉", "Rosa", "Blush"),
        "option.value.ink": tri("墨色", "Tinta", "Ink"),
        "option.value.navy": tri("藏青", "Azul marino", "Navy"),
        "option.value.sand": tri("沙色", "Arena", "Sand"),
        "option.value.amber": tri("琥珀黄", "Ámbar", "Amber"),
        "option.value.slate": tri("石板灰", "Pizarra", "Slate"),
        "option.value.clay": tri("陶土", "Arcilla", "Clay"),
        "option.value.coral": tri("珊瑚", "Coral", "Coral"),
        "option.value.natural": tri("原色", "Natural", "Natural"),
        "option.value.s": tri("S 号", "Talla S", "Size S"),
        "option.value.m": tri("M 号", "Talla M", "Size M"),
        "option.value.l": tri("L 号", "Talla L", "Size L"),
        "option.value.xl": tri("XL 号", "Talla XL", "Size XL"),

        // Consent scopes
        "consent.scope.profile_storage": tri("资料保存", "Guardar perfil", "Profile storage"),
        "consent.scope.external_ai": tri("外部 AI 处理", "IA externa", "External AI"),
        "consent.scope.photo_processing": tri("照片处理", "Procesar foto", "Photo processing"),
        "consent.scope.model_generation": tri("模型生成", "Generar modelo", "Model generation"),

        // Themes
        "theme.system": tri("跟随系统", "Sistema", "System"),
        "theme.light": tri("浅色", "Claro", "Light"),
        "theme.dark": tri("深色", "Oscuro", "Dark"),

        // Job stages / statuses
        "stage.queued": tri("排队中", "En cola", "Queued"),
        "stage.recognize": tri("识别照片", "Reconociendo foto", "Recognizing photo"),
        "stage.template_select": tri("选择模板", "Eligiendo plantilla", "Selecting template"),
        "stage.texture_personalize": tri("纹理个性化", "Personalizando textura", "Personalizing texture"),
        "stage.optimize": tri("优化资产", "Optimizando", "Optimizing"),
        "stage.convert_usdz": tri("转换 USDZ", "Convirtiendo USDZ", "Converting USDZ"),
        "stage.done": tri("完成", "Listo", "Done"),
        "status.queued": tri("排队中", "En cola", "Queued"),
        "status.dispatching": tri("派发中", "Despachando", "Dispatching"),
        "status.processing": tri("处理中", "Procesando", "Processing"),
        "status.succeeded": tri("已完成", "Completado", "Succeeded"),
        "status.failed": tri("失败", "Fallido", "Failed"),
        "status.cancel_requested": tri("取消中", "Cancelando", "Cancelling"),
        "status.cancelled": tri("已取消", "Cancelado", "Cancelled"),

        // Privacy statuses
        "privacy.status.received": tri("已收到", "Recibida", "Received"),
        "privacy.status.processing": tri("处理中", "Procesando", "Processing"),
        "privacy.status.completed": tri("已完成", "Completada", "Completed"),
        "privacy.status.failed": tri("失败", "Fallida", "Failed"),

        // Accessibility / misc
        "a11y.cart": tri("购物车", "Carrito", "Cart"),
        "a11y.close": tri("关闭", "Cerrar", "Close"),
        "a11y.demoBadge": tri("演示环境标识", "Marca de entorno demo", "Demo environment badge"),
        "misc.demoOnly": tri("仅演示", "Solo demo", "Demo only"),
        "misc.orderPlaced": tri("订单已创建", "Pedido creado", "Order created")
    ]
}
