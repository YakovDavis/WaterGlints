#version 330

#define FLT_MAX 3.402823466e+38

//=============================================================================
//============================= Vertex information ============================
//=============================================================================
in vec2 TexCoord;
in vec3 VertexPos;
in vec3 VertexNorm;
in vec3 VertexTang;

//=============================================================================
//============================= Light information =============================
//=============================================================================
uniform struct PointLightInfo {
  vec4 Position;  // Light position in world coords.
  vec3 L;         // Intensity
} PointLight;

uniform struct DirLightInfo {
  vec2 ThetaPhi;  // Light direction in world coords.
  vec3 L;         // Intensity
} DirLight;

uniform bool UseEnvMap;
uniform float ScaleIntensityEnvMap;

//=============================================================================
//========================== Material information =============================
//=============================================================================
uniform struct MaterialInfo {
  float Alpha;                // Material isotropic roughness
  float LogMicrofacetDensity; // Logarithmic microfacet density
  float MicrofacetRelativeArea;
} Material;


uniform bool UseBump;
uniform bool UseDiffuseTex;
uniform bool UseSpecularTex;
uniform vec3 Kd;
uniform vec3 Ks;

uniform vec3  UserSigmasRho;
uniform float UserMicrofacetRelativeArea;
uniform float UserLogMicrofacetDensity;
uniform bool  OverrideMaterials;

uniform vec2  ScaleUV = vec2(1.);

uniform float MaxAnisotropy;

//=============================================================================
//========================== Dictionary information ===========================
//=============================================================================
uniform struct DictionaryInfo {
  float Alpha;
  int N;
  int NLevels;
  int Pyramid0Size;
} Dictionary;

uniform vec3  CameraPosition;

//=============================================================================
//================ Geometric Glint Anti-Aliasing parameters ===================
//=============================================================================
uniform float KernelSize;
uniform bool  Filter;
uniform bool UseHemisDerivatives;

// Activate LEAN
uniform int   LeanMode;

// Activate reference
uniform bool  ComputeReference;

// Only specular
uniform bool OnlySpecular;

//=============================================================================
//============================== Textures =====================================
//=============================================================================

uniform sampler1DArray DictionaryTex;
uniform sampler2D DiffuseTex;
uniform sampler2D SlopeTex;
uniform sampler2D SecondMomentTex;
uniform sampler2D SpecularTex;
uniform sampler2D MaskTex;
uniform samplerCube EnvMap;

layout( location = 0 ) out vec4 FragColor;

//=============================================================================
//=========================== Constants =======================================
//=============================================================================
const float m_pi = 3.141592;       /* MathConstant: PI             */
const float m_i_sqrt_2 = 0.707106; /* MathConstant: 1/sqrt(2)      */


//=============================================================================
//================== Compute LOD from roughness (Env map) =====================
//=============================================================================
float lod_from_roughness(vec2 roughness)
{
    return 9. * sqrt(max(roughness.x, roughness.y));
}

//=============================================================================
//================== Slope to normal transformation ===========================
//=============================================================================
vec3 slope_to_normal(vec2 slope){
    float norm = sqrt(1 + slope.x * slope.x + slope.y * slope.y);
    return vec3(-slope.x,-slope.y,1.)/norm;
}

//=============================================================================
//============== Non axis aligned anisotropic Beckmann ========================
//=============================================================================
float non_axis_aligned_anisotropic_beckmann
    (float x, float y, float sigma_x, float sigma_y, float rho)
{
    float x_sqr = x*x;
    float y_sqr = y*y;
    float sigma_x_sqr = sigma_x*sigma_x;
    float sigma_y_sqr = sigma_y*sigma_y;

    float z = ((x_sqr/sigma_x_sqr) - ( (2. * rho *x*y) 
                  / (sigma_x * sigma_y)) + (y_sqr/sigma_y_sqr)) ;
    return exp( - z / (2. * (1. - rho * rho))) 
        / ( 2. * m_pi * sigma_x * sigma_y * sqrt(1. - rho * rho));
}

//=============================================================================
//===================== Inverse error function ================================
//=============================================================================
float erfinv(float x) {
    float w, p;
    w = -log((1.0-x)*(1.0+x));
    if(w < 5.000000) {
        w = w - 2.500000;
        p = 2.81022636e-08;
        p = 3.43273939e-07 + p*w;
        p = -3.5233877e-06 + p*w;
        p = -4.39150654e-06 + p*w;
        p = 0.00021858087 + p*w;
        p = -0.00125372503 + p*w;
        p = -0.00417768164 + p*w;
        p = 0.246640727 + p*w;
        p = 1.50140941 + p*w;
    }
    else {
        w = sqrt(w) - 3.000000;
        p = -0.000200214257;
        p = 0.000100950558 + p*w;
        p = 0.00134934322 + p*w;
        p = -0.00367342844 + p*w;
        p = 0.00573950773 + p*w;
        p = -0.0076224613 + p*w;
        p = 0.00943887047 + p*w;
        p = 1.00167406 + p*w;
        p = 2.83297682 + p*w;
    }
    return p*x;
}
//=============================================================================
//======================== Hash function ======================================
//======================== Inigo Quilez =======================================
//================ https://www.shadertoy.com/view/llGSzw ======================
//=============================================================================
float hashIQ(uint n)
{
    // integer hash copied from Hugo Elias
    n = (n << 13U) ^ n;
    n = n * (n * n * 15731U + 789221U) + 1376312589U;
    return float(n & 0x7fffffffU) / float(0x7fffffff);
}

//=============================================================================
//================== Pyramid size at LOD level ================================
//=============================================================================
int pyramidSize(int level)
{
    return int(pow(2., float(Dictionary.NLevels - 1 - level)));
}

//=============================================================================
//=============== Sampling from a normal distribution =========================
//=============================================================================
float sampleNormalDistribution(float U, float mu, float sigma)
{
    float x = sigma * 1.414213f * erfinv(2.0f * U - 1.0f) + mu;
    return x;
}

//=============================================================================
//===================== Spatially-varying, multiscale, ========================
//=============== and transformed slope distribution function  ================
//=============================== Equation 4 ==================================
//=============================================================================
float P22_M(vec2 slope_h, int l, int s0, int t0, 
            vec2 slope_dx, vec2 slope_dy,
            vec3 sigma_x_y_rho, float l_dist)
{
    // Coherent index
    int twoToTheL = int(pow(2.,float(l)));
    s0 *= twoToTheL;
    t0 *= twoToTheL;

    // Seed pseudo random generator
    uint rngSeed = uint(s0 + 1549 * t0);

    float uMicrofacetRelativeArea = hashIQ(rngSeed * 13U);
    // Discard cells by using microfacet relative area
    if (OverrideMaterials && 
        uMicrofacetRelativeArea > UserMicrofacetRelativeArea ||
        !OverrideMaterials && 
        uMicrofacetRelativeArea > Material.MicrofacetRelativeArea)
        return 0.f;

    float uDensityRandomisation = hashIQ(rngSeed * 2171U);

    // Fix density randomisation to 2 to have better appearance
    float densityRandomisation = 2.;

    // Sample a Gaussian to randomise the distribution LOD around the 
    // distribution level l_dist
    l_dist = sampleNormalDistribution(uDensityRandomisation, l_dist, 
                                      densityRandomisation);

    l_dist = clamp(int(round(l_dist)), 0, Dictionary.NLevels);

    // Recover roughness and slope correlation factor
    float sigma_x = sigma_x_y_rho.x;
    float sigma_y = sigma_x_y_rho.y;
    float rho     = sigma_x_y_rho.z;

    // If we are too far from the surface, the SDF is a gaussian.
    if (l_dist == Dictionary.NLevels){
        return non_axis_aligned_anisotropic_beckmann(slope_h.x, slope_h.y,
                sigma_x, sigma_y, rho);
    }

    // Random rotations to remove glint alignment
    float uTheta = hashIQ(rngSeed);
    float theta = 2.0 * m_pi * uTheta;

    float cosTheta = cos(theta);
    float sinTheta = sin(theta);

    //=========================================================================
    //========= Linearly transformed isotropic Beckmann distribution ==========
    //=========================================================================

    float SIGMA_DICT = Dictionary.Alpha * m_i_sqrt_2;
    float tmp1 =  SIGMA_DICT / (sigma_x * sqrt(1. - rho * rho));
    float tmp2 = -SIGMA_DICT * rho / (sigma_y * sqrt(1. - rho * rho));
    float tmp3 =  SIGMA_DICT / sigma_y;

    //=========================================================================
    //============================= Contribution 2 ============================
    //======================= Slope correlation factor ========================
    //============================== Equation 18 ==============================
    // Former inverse transformation matrix (Chermain et al. 2020) was: 
    // SIGMA_DICT * mat2(1. / sigma_x, 0.     ,
    //                   0.          , 1. / sigma_y)
    //=========================================================================

    mat2 invM = mat2(tmp1, 0.,     // first column
                     tmp2, tmp3 ); // second column

    //=========================================================================
    //========================== END Contribution 2 ===========================
    //=========================================================================

    // Apply random rotation
    mat2 invR = mat2(cosTheta, -sinTheta,  // first column
                     sinTheta,  cosTheta); // second column
    invM = invR*invM;

    // Get back to original space
    // Equation 5
    vec2 slope_h_o = invM * slope_h;

    // The SDF is an even function
    vec2 abs_slope_h_o = vec2(abs(slope_h_o.x), abs(slope_h_o.y));

    int distPerChannel = Dictionary.N / 3;
    float alpha_dist_isqrt2_4 = Dictionary.Alpha * m_i_sqrt_2 * 4.f;

    // After 4 standard deviations, the SDF equals zero
    if (abs_slope_h_o.x > alpha_dist_isqrt2_4 
        || abs_slope_h_o.y > alpha_dist_isqrt2_4)
        return 0.f;

    float u1 = hashIQ(rngSeed * 16807U);
    float u2 = hashIQ(rngSeed * 48271U);

    int i = int(u1 * float(Dictionary.N));
    int j = int(u2 * float(Dictionary.N));

    // 3 distributions values in one texel
    int distIdxXOver3 = i / 3;
    int distIdxYOver3 = j / 3;

    float texCoordX = abs_slope_h_o.x / alpha_dist_isqrt2_4;
    float texCoordY = abs_slope_h_o.y / alpha_dist_isqrt2_4;

    // We also need to scale the derivatives,
    // as slope_h, to maintained coherence
    slope_dx = slope_dx / alpha_dist_isqrt2_4;
    slope_dy = slope_dy / alpha_dist_isqrt2_4;

    vec3 P_20_o, P_02_o;
    //=========================================================================
    //=========================== Contribution 1 ==============================
    //================================ GGAA ===================================
    //=========================================================================
    if(Filter)
    {      
        // As for the distribution, we transform the filtering kernel
        vec2 transformed_slope_dx = invM * slope_dx;
        vec2 transformed_slope_dy = invM * slope_dy;

        // Scale the kernel by user parameter
        transformed_slope_dx *= KernelSize;
        transformed_slope_dy *= KernelSize;
        
        P_20_o = textureGrad(DictionaryTex, 
                             vec2(texCoordX, 
                                  l_dist * distPerChannel + distIdxXOver3),
                             transformed_slope_dx.x, 
                             transformed_slope_dy.x).rgb;

        P_02_o = textureGrad(DictionaryTex,
                             vec2(texCoordY, 
                                  l_dist * distPerChannel + distIdxYOver3), 
                             transformed_slope_dx.y,
                             transformed_slope_dy.y).rgb;
    }
    //=========================================================================
    //========================= END Contribution 1 ============================
    //=========================================================================
    else // Without geometric glint anti-aliasing
    {
        P_20_o = textureLod(DictionaryTex,
                            vec2(texCoordX,
                                 l_dist * distPerChannel + distIdxXOver3),
                            0.).rgb;
        P_02_o = textureLod(DictionaryTex, 
                            vec2(texCoordY,
                                 l_dist * distPerChannel + distIdxYOver3), 
                            0.).rgb;
    }

    // Equation 15
    return P_20_o[int(mod(i, 3))] * P_02_o[int(mod(j, 3))] * determinant(invM);
}

//=============================================================================
//===================== P-SDF for a discrete LOD ==============================
//=============================================================================

// Most of this function is similar to pbrt-v3 EWA function,
// which itself is similar to Heckbert 1889 algorithm, 
// http://www.cs.cmu.edu/~ph/texfund/texfund.pdf, Section 3.5.9.
// Go through cells within the pixel footprint for a givin LOD
float P22__glint_discrete_LOD(int l, vec2 slope_h, vec2 st, vec2 dst0, 
                              vec2 dst1, vec2 slope_dx, vec2 slope_dy, 
                              vec3 sigma_x_y_rho, float l_dist)
{

    // Convert surface coordinates to appropriate scale for level
    float pyrSize = pyramidSize(l);
    st[0] = st[0] * pyrSize - 0.5f;
    st[1] = st[1] * pyrSize - 0.5f;
    dst0[0] *= pyrSize;
    dst0[1] *= pyrSize;
    dst1[0] *= pyrSize;
    dst1[1] *= pyrSize;

    // Compute ellipse coefficients to bound filter region
    float A = dst0[1] * dst0[1] + dst1[1] * dst1[1] + 1.;
    float B = -2. * (dst0[0] * dst0[1] + dst1[0] * dst1[1]);
    float C = dst0[0] * dst0[0] + dst1[0] * dst1[0] + 1.;
    float invF = 1. / (A * C - B * B * 0.25f);
    A *= invF;
    B *= invF;
    C *= invF;

    // Compute the ellipse's bounding box in texture space
    float det = -B * B + 4 * A * C;
    float invDet = 1 / det;
    float uSqrt = sqrt(det * C), vSqrt = sqrt(A * det);
    int s0 = int(ceil(st[0] - 2. * invDet * uSqrt));
    int s1 = int(floor(st[0] + 2. * invDet * uSqrt));
    int t0 = int(ceil(st[1] - 2. * invDet * vSqrt));
    int t1 = int(floor(st[1] + 2. * invDet * vSqrt));

    // Scan over ellipse bound and compute quadratic equation
    float sum = 0.f;
    float sumWts = 0;
    int nbrOfIter = 0;
    for (int it = t0; it <= t1; ++it)
    {
        float tt = it - st[1];
        for (int is = s0; is <= s1; ++is)
        {
            float ss = is - st[0];
            // Compute squared radius 
            // and filter SDF if inside ellipse
            float r2 = A * ss * ss + B * ss * tt + C * tt * tt;
            if (r2 < 1)
            {
                // Weighting function used in pbrt-v3 EWA function
                float alpha = 2;
                float W_P = exp(-alpha * r2) - exp(-alpha);
                sum += P22_M(slope_h, l, is, it, 
                             slope_dx, slope_dy, 
                             sigma_x_y_rho, l_dist) * W_P;
                sumWts += W_P;
            }
            nbrOfIter++;
            // Guardrail (Extremely rare case.)
            if (nbrOfIter > 100)
                break;
        }
        // Guardrail (Extremely rare case.)
        if (nbrOfIter > 100)
            break;
    }
    return sum/sumWts;
}

//=============================================================================
//====YAKOV: Start of the contribution part 1==================================
//=============================================================================

//=============================================================================
//======== Tangent space maths ================================================
//=============================================================================
float cos_theta(const vec3 w)       {return w.z;}
float cos_2_theta(const vec3 w)     {return w.z*w.z;}
float sin_2_theta(const vec3 w)     {return max(0.f, 1.f - cos_2_theta(w));}
float sin_theta(const vec3 w)       {return sqrt(sin_2_theta(w));}
float tan_theta(const vec3 w)       {return sin_theta(w) / cos_theta(w);}
float cos_phi(const vec3 w)         {return (sin_theta(w) == 0.f) ? 1.f : clamp(w.x / sin_theta(w), -1.f, 1.f);}
float sin_phi(const vec3 w)         {return (sin_theta(w) == 0.f) ? 0.f : clamp(w.y / sin_theta(w), -1.f, 1.f);}
float cos_2_phi(const vec3 w)       {return cos_phi(w) * cos_phi(w);}
float sin_2_phi(const vec3 w)       {return sin_phi(w) * sin_phi(w);} 

//=============================================================================
//======== Shifting view/incident direction for off-center V-cavity ===========
//=============================================================================
vec3 shift_W(vec3 w, // vector to be transformed
             float x0, float y0 // average slope
             )
{
    vec3 shifted_w = vec3(0.);

    float cos_phi = cos_phi(w);
    float sin_phi = sin_phi(w);
    float tan_theta = tan_theta(w);

    vec2 w_xy = normalize(vec2(cos_phi, sin_phi)); // vector projected in tangent space XY
    float mu_phi = w_xy.x * x0 + w_xy.y * y0;

    float cos_mu_phi = cos(mu_phi);
    float sin_mu_phi = sin(mu_phi);

    float w_z = 1. / tan_theta;

    shifted_w.xy = w_xy;

    float w_xy_length = length(w_xy);

    float shifted_w_z = 0.;
    if (cos_mu_phi < 0.) {
        shifted_w_z = w_xy_length * (w_xy_length * cos_mu_phi - w_z * sin_mu_phi) / (w_z * cos_mu_phi + w_xy_length * sin_mu_phi);
    }
    else
    {
        shifted_w_z = w_xy_length * (w_z * cos_mu_phi + w_xy_length * sin_mu_phi) / (w_xy_length * cos_mu_phi - w_z * sin_mu_phi);
    }

    return normalize(vec3(w_xy, shifted_w_z));
}

//=============================================================================
//======== Fresnel ============================================================
//=============================================================================
vec3 fresnel_schlick(float wo_dot_wh, vec3 F0)
{
    return F0 + (1. - F0) * pow(1. - wo_dot_wh, 5.);
}

//=============================================================================
//====YAKOV: End of the contribution part 1====================================
//=============================================================================

//=============================================================================
//======== Evaluation of the procedural physically based glinty BRDF ==========
//=============================================================================
vec3 f_P(vec3 wo, vec3 wi, vec3 wg, vec3 sigmas_rho, vec3 slope_projected_area)
{
    if (wo.z <= 0.)
        return vec3(0., 0., 0.);
    if (wi.z <= 0.)
        return vec3(0., 0., 0.);

    vec3 wh = normalize(wo + wi);
    if (wh.z <= 0.)
        return vec3(0., 0., 0.);

    // Local masking shadowing
    if (dot(wo, wh) <= 0. || dot(wi, wh) <= 0.)
        return vec3(0.,0.,0.);

    // Compute texture derivatives
    vec2 texCoord = TexCoord * ScaleUV;
    vec2 dst0 = dFdx(texCoord);
    vec2 dst1 = dFdy(texCoord);

    // Normal to slope
    vec2 slope_h = vec2(-wh.x / wh.z, -wh.y / wh.z);

    vec2 slope_dx;
    vec2 slope_dy;
    if(UseHemisDerivatives){
        // Derivatives in the projected hemispherical domain
        vec2 projected_half_vector = vec2(wh.x, wh.y);
        slope_dx = dFdx(projected_half_vector);
        slope_dy = dFdy(projected_half_vector);
    }
    else{
        slope_dx = dFdx(slope_h);
        slope_dy = dFdy(slope_h);
    }

    vec3 D_P = vec3(0.);
    float P22_P = 0.;

    //=========================================================================
    // Similar to pbrt-v3 MIPMap::Lookup function, 
    // http://www.pbr-book.org/3ed-2018/Texture/Image_Texture.html#EllipticallyWeightedAverage

    // Compute ellipse minor and major axes
    float dst0LengthSquared = length(dst0);
    dst0LengthSquared *= dst0LengthSquared;
    float dst1LengthSquared = length(dst1);
    dst1LengthSquared *= dst1LengthSquared;

    if (dst0LengthSquared < dst1LengthSquared)
    {
        // Swap dst0 and dst1
        vec2 tmp = dst0;
        dst0 = dst1;
        dst1 = tmp;
    }
    float majorLength = length(dst0);
    float minorLength = length(dst1);

    // Clamp ellipse eccentricity if too large
    if (minorLength * MaxAnisotropy < majorLength
        && minorLength > 0.)
    {
        float scale = majorLength / (minorLength * MaxAnisotropy);
        dst1 *= scale;
        minorLength *= scale;
    }
    //=========================================================================

    // Without footprint -> no reflection
    if (minorLength == 0) D_P = vec3(0.,0.,0.);
    else
    {
        // Choose LOD
        float l =
            max(0., Dictionary.NLevels - 1. + log2(minorLength));
        int il = int(floor(l));

        float w = l - float(il);

        // Number of microfacets in a cell at level il
        float n_il = pow(2., float(2 * il - (2 * (Dictionary.NLevels - 1))));
        if(!OverrideMaterials)
            n_il *= exp(Material.LogMicrofacetDensity);
        else
            n_il *= exp(UserLogMicrofacetDensity);
        // Corresponding continuous distribution LOD
        float LOD_dist_il = log(n_il) / 1.38629; // 2. * log(2) = 1.38629

        // Number of microfacets in a cell at level il + 1
        float n_ilp1 = 
            pow(2., float(2 * (il + 1) - (2 * (Dictionary.NLevels - 1))));
        if(!OverrideMaterials)
            n_ilp1 *= exp(Material.LogMicrofacetDensity);
        else
            n_ilp1 *= exp(UserLogMicrofacetDensity);
        // Corresponding continuous distribution LOD
        float LOD_dist_ilp1 = log(n_ilp1) / 1.38629; // 2. * log(2) = 1.38629

        float P22_P_il = non_axis_aligned_anisotropic_beckmann
            (slope_h.x, slope_h.y, sigmas_rho.x, sigmas_rho.y, sigmas_rho.z);
        float P22_P_ilp1 = P22_P_il;

        float microfacetRelativeArea = Material.MicrofacetRelativeArea;
        if(OverrideMaterials) microfacetRelativeArea = 
            UserMicrofacetRelativeArea;
        bool opti = microfacetRelativeArea > 0.99;

        if(int(round(LOD_dist_il)) < Dictionary.NLevels || !opti)
            P22_P_il = P22__glint_discrete_LOD
                (il, slope_h, texCoord, dst0, dst1, 
                 slope_dx, slope_dy, sigmas_rho, LOD_dist_il);

        if(int(round(LOD_dist_il)) < Dictionary.NLevels || !opti)
            P22_P_ilp1 = P22__glint_discrete_LOD
                (il+1, slope_h, texCoord, dst0, dst1, 
                 slope_dx, slope_dy, sigmas_rho, LOD_dist_ilp1);

        P22_P = mix(P22_P_il, P22_P_ilp1, w);

        D_P = vec3(P22_P / (wh.z * wh.z * wh.z * wh.z));
    }

    float h_dot_v = clamp(dot(wo, wh), 0., 1.);

    //=============================================================================
    //====YAKOV: Start of the contribution part 2==================================
    //=============================================================================
    float n_dot_l = dot(wg, wi);

    vec3 wh_shifted = shift_W(wh, slope_projected_area.x, slope_projected_area.y);

    // V-cavity masking shadowing
    float G1wowh = min(1., 2. * wh_shifted.z * wo.z / dot(wo, wh_shifted));
    float G1wiwh = n_dot_l > 0. ? min(1., 2. * wh_shifted.z * wi.z / dot(wi, wh_shifted)) : 0.;
    float G = clamp(G1wowh * G1wiwh, 0., 1.);

    // Fresnel
    vec3 F = fresnel_schlick(h_dot_v, vec3(0.2, 0.2, 0.2)); // YAKOV

    // (wi dot wg) is cancelled by
    // the cosine weight in the rendering equation
    return slope_projected_area.z * (F * G * D_P) / 4.;
    //=============================================================================
    //====YAKOV: End of the contribution part 2==================================
    //=============================================================================
}

//=============================================================================
//====================== Evaluate rendering equation ==========================
//=============================================================================
void main()
{
    if(texture(MaskTex, TexCoord * ScaleUV).x < 0.1)
        discard;

    vec3 woWorld = normalize(CameraPosition - VertexPos);

    // Point light direction
    vec3 wiWorld_pl  = normalize(PointLight.Position.xyz - VertexPos);

    // Directional light direction
    float cosThetaDir = cos(DirLight.ThetaPhi.x);
    float sinThetaDir = sin(DirLight.ThetaPhi.x);
    float cosPhiDir = cos(DirLight.ThetaPhi.y);
    float sinPhiDir = sin(DirLight.ThetaPhi.y);
    vec3 wiWorld_dir = vec3(cosPhiDir * sinThetaDir, 
                            cosThetaDir,
                            sinPhiDir * sinThetaDir);

    vec3 binormal = cross(VertexNorm, VertexTang);

    // Matrix for transformation to tangent space
    mat3 toLocal = mat3(
        VertexTang.x, binormal.x, VertexNorm.x,
        VertexTang.y, binormal.y, VertexNorm.y,
        VertexTang.z, binormal.z, VertexNorm.z ) ;

    mat3 toWorld = inverse(toLocal);

    vec2 first_order_moment;
    vec3 second_order_moment;

    if(UseBump){
        if(ComputeReference){
            first_order_moment = textureLod(SlopeTex,TexCoord * ScaleUV, 0.).xy;
            second_order_moment = textureLod(SecondMomentTex,TexCoord * ScaleUV, 0.).xyz;
        }
        else{
            first_order_moment = texture(SlopeTex,TexCoord * ScaleUV).xy;
            second_order_moment = texture(SecondMomentTex,TexCoord * ScaleUV).xyz;
        }
    } else {
        first_order_moment = vec2(0.);
        second_order_moment = vec3(0.);
    }
    

    vec3 normal = slope_to_normal(first_order_moment);
    vec3 normalWorld = normalize(toWorld * normal);

    // Correct normal (back facing normal case)
    if (dot(normalWorld, woWorld) <= 0.0)
        normalWorld = normalize(normalWorld - 1.01*woWorld *
                                dot(normalWorld, woWorld));

    // Gram-Schmidt process (orthogolize shading frame)
    vec3 tangShWorld = 
        normalize(VertexTang - (dot(normalWorld,VertexTang) /
                  dot(normalWorld,normalWorld)) * normalWorld);

    vec3 binormalShWorld = cross(normalWorld, tangShWorld);

    // Matrix for transformation to shading space
    mat3 toShading = mat3(
        tangShWorld.x, binormalShWorld.x, normalWorld.x,
        tangShWorld.y, binormalShWorld.y, normalWorld.y,
        tangShWorld.z, binormalShWorld.z, normalWorld.z ) ;

    vec3 wiWorld_env  = normalize(reflect(-woWorld,normalWorld));

    // Transform light direction and view direction to tangent space
    vec3 wi_pl  = toShading * wiWorld_pl;
    wi_pl = normalize(wi_pl);
    vec3 wi_dir  = toShading * wiWorld_dir;
    wi_dir = normalize(wi_dir);
    //if(wi_dir.z <= 0.) wi_dir *= -1.;
    vec3 wo = toShading * woWorld;
    wo = normalize(wo);
    vec3 wg = toShading * normalWorld; // YAKOV: Geometric Normal in tangent space
    wg = normalize(wg);

    //=========================================================================
    //====================== Retrieve material information ====================
    //=========================================================================

    float sigma_x_mat = Material.Alpha * m_i_sqrt_2;
    float sigma_y_mat = Material.Alpha * m_i_sqrt_2;
    float rho_mat     = 0.;
        
    if(OverrideMaterials){
        sigma_x_mat = UserSigmasRho.x;
        sigma_y_mat = UserSigmasRho.y;
        rho_mat = UserSigmasRho.z;
    }

    //=========================================================================
    //========================== Normal map filtering =========================
    //=========================================================================
    float sigma_x, sigma_y, rho;

    float normal_map_std_slope_x_sqr = 
        second_order_moment.x - first_order_moment.x 
        * first_order_moment.x;
    float normal_map_std_slope_y_sqr =
        second_order_moment.y - first_order_moment.y
        * first_order_moment.y;
    
    normal_map_std_slope_x_sqr = 
        clamp(normal_map_std_slope_x_sqr, 0.0001, 1.);
    normal_map_std_slope_y_sqr = 
        clamp(normal_map_std_slope_y_sqr, 0.0001, 1.);

    float sigma_x_normals =  sqrt(normal_map_std_slope_x_sqr);
    float sigma_y_normals =  sqrt(normal_map_std_slope_y_sqr);

    float rho_normals = second_order_moment.z
        - first_order_moment.x * first_order_moment.y;
    if(normal_map_std_slope_x_sqr == 0.0001 || 
       normal_map_std_slope_y_sqr == 0.0001){
        sigma_x_normals = 0.;
        sigma_y_normals = 0.;
        rho_normals = 0.;
    }
    else{
        rho_normals /= 
            sigma_x_normals * sigma_y_normals;
        rho_normals = clamp(rho_normals, -0.99, 0.99);
    }

    if(LeanMode == 2 || ComputeReference){ // LEAN mapping not used
        sigma_x = sigma_x_mat;
        sigma_y = sigma_y_mat;
        rho     = rho_mat;
    }
    else if(LeanMode == 0){ // LEAN mapping used
        sigma_x = 
            sqrt(sigma_x_mat*sigma_x_mat + sigma_x_normals*sigma_x_normals);
        sigma_y =
            sqrt(sigma_y_mat*sigma_y_mat + sigma_y_normals*sigma_y_normals);
        rho = (rho_mat * sigma_x_mat * sigma_y_mat 
               + rho_normals * sigma_x_normals * sigma_y_normals) 
              / (sigma_x * sigma_y) ;
    }
    else if (LeanMode == 1){ // LEAN mapping used without covariance
        sigma_x = 
            sqrt(sigma_x_mat*sigma_x_mat + sigma_x_normals*sigma_x_normals);
        sigma_y = 
            sqrt(sigma_y_mat*sigma_y_mat + sigma_y_normals*sigma_y_normals);
        rho     = rho_mat;
    }

    // Clamp values
    sigma_x = clamp(sigma_x, 0.01, 1.);
    sigma_y = clamp(sigma_y, 0.01, 1.);
    rho = clamp(rho, -0.99, 0.99);

    vec3 wn = vec3(-first_order_moment.x, -first_order_moment.y, 1.) / sqrt(1 + first_order_moment.x * first_order_moment.x + first_order_moment.y * first_order_moment.y);

    float projected_area = clamp(dot(wn, wo) / dot(wn, wg), 1., FLT_MAX);

    vec3 slope_projected_area = vec3(first_order_moment, projected_area);

    //=========================================================================
    //============== Retrieve diffuse and specular coefficients ===============
    //=========================================================================

    // Retrieve diffuse coeff
    vec3 kd;
    if(UseDiffuseTex)
        kd = texture(DiffuseTex, TexCoord * ScaleUV).rgb;
    else
        kd = Kd;
    // From perceptual to linear space (inverse gamma function)
    kd = pow( kd, vec3(2.2) );

    // Retrieve specular coeff
    vec3 ks;
    if(UseSpecularTex)
        ks = texture(SpecularTex, TexCoord * ScaleUV).xyz;
    else 
        ks = Ks;

    //=========================================================================
    //============================= Point light ===============================
    //=========================================================================
    vec3 radiance_specular_pl = vec3(0);
    vec3 radiance_diffuse_pl = vec3(0);
    vec3 radiance_pl = vec3(0);
    
    float distanceSquared = distance(VertexPos, PointLight.Position.xyz);
    distanceSquared *= distanceSquared;
    vec3 Li = PointLight.L / distanceSquared;
    
    // Diffuse part
    radiance_diffuse_pl = (kd / m_pi) * wi_pl.z;
    if(wo.z <= 0. || wi_pl.z <= 0.)
        radiance_diffuse_pl = vec3(0.);

    // Specular part
    if(wo.z <= 0. || wi_pl.z <= 0. || (ks.x == 0. && ks.y == 0. && ks.z == 0.)
        || dot(Li,Li) == 0.f)
        radiance_specular_pl = vec3(0.);
    else
        // Compute specular radiance
        radiance_specular_pl = ks * f_P(wo, wi_pl, wg, vec3(sigma_x, sigma_y, rho), slope_projected_area);

    radiance_pl = (radiance_diffuse_pl + radiance_specular_pl) * 0.5 * Li;

    //=========================================================================
    //========================== Directional light ============================
    //=========================================================================
    vec3 radiance_specular_dir = vec3(0);
    vec3 radiance_diffuse_dir = vec3(0);
    vec3 radiance_dir = vec3(0);
    
    vec3 Li_dir = DirLight.L;
    
    // Diffuse part
    radiance_diffuse_dir = (kd / m_pi) * wi_dir.z;
    if(wo.z <= 0. || wi_dir.z <= 0.)
        radiance_diffuse_dir = vec3(0.);

    // Specular part
    if(wi_dir.z > 0.f && wo.z > 0.f && (ks.x != 0. || ks.y != 0. && ks.z != 0.)){
        // Compute specular radiance
        radiance_specular_dir = ks * f_P(wo, wi_dir, wg, vec3(sigma_x, sigma_y, rho), slope_projected_area);
    }

    radiance_dir = (radiance_diffuse_dir + radiance_specular_dir) * 0.5 * Li_dir;

    //=========================================================================
    //============================= Env map ===================================
    //=========================================================================

    vec3 radiance_env;
    vec3 radiance_diffuse_env;
    vec3 radiance_specular_env;

    if(UseEnvMap){
        float lod = lod_from_roughness(vec2(sigma_x, sigma_y));

        if(dot(VertexNorm,wiWorld_env) < 0.)
            wiWorld_env = -wiWorld_env;

        radiance_specular_env = textureLod(EnvMap, wiWorld_env, lod).xyz;
        radiance_diffuse_env = textureLod(EnvMap, normalWorld, 6.).xyz;
        radiance_env = (kd * radiance_diffuse_env + ks * radiance_specular_env)
            * 0.5 * ScaleIntensityEnvMap;

    } else
        radiance_env = vec3(0.);
    
    //=========================================================================
    //==================== Addition all incomming radiance ====================
    //=========================================================================
    
    // !Gamma correction and tone mapping is done during the post processing.!
    FragColor = vec4(radiance_env + radiance_dir + radiance_pl, 1);
    if(OnlySpecular)
        FragColor = vec4(radiance_specular_dir * 0.5 * Li_dir 
                         + radiance_specular_pl * 0.5 * Li, 1);
}
