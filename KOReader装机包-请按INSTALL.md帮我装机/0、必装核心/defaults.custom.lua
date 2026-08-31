-- 低内存保护：把页面缓存预算比例从 0.4 压到 0.15，给 cvm/后台任务让内存
return {
    ["DGLOBAL_CACHE_FREE_PROPORTION"] = 0.15,
}
