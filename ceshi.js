/*
 * Quantumult X Script: 修改订购请求体
 * Type: script-request-body
 * Regex: ^https:\/\/cap\.chinaunicom\.cn\/cap\/auc\/proinfoauth\/
 */

let body = $request.body;
let obj = {};

try {
    obj = JSON.parse(body);
} catch (e) {
    console.log("Failed to parse request body as JSON:", e);
    $done({}); // 如果不是JSON，则不处理，直接放行原始请求
    return;
}

// 检查并修改 PRODUCT_ID
if (obj.PRODUCT_ID) {
    const oldProductId = obj.PRODUCT_ID;
    const newProductId = "4900725000"; // 您想要替换成的新产品代码

    if (oldProductId !== newProductId) {
        obj.PRODUCT_ID = newProductId;
        obj.PRODUCT_NAME = "新会员产品"; // 相应地修改产品名称
        console.log(`PRODUCT_ID changed from ${oldProductId} to ${newProductId}`);
    }
}

// !!! 再次强调：AUTH_NO 和 CLIENT_SECRET 仍需确保有效 !!!
// 如果它们过期，您需要通过抓包获取最新值并手动更新到原始请求中（例如，通过App重新触发一次订购流程）。
// 这个脚本不会自动更新这些动态参数。

$done({body: JSON.stringify(obj)}); // 将修改后的JSON体转换回字符串并放行请求
